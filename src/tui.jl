# Entry point for the multi-line TUI. The real work lives in
# `tui_model.jl`, `tui_buffer.jl`, `tui_eval.jl`, `tui_search.jl`,
# `tui_bindings.jl`, and `tui_view.jl`, which are all included by
# `Ressac.jl` before this file. This module just defines the public
# session-management API: `start_live!`, `stop_live!`, `restart_live!`,
# `live`, plus the implicit-scheduler helpers (`d!`, `unset!`,
# `hush_all!`, `cps!`).

const _LIVE_SCHEDULER = Ref{Union{Scheduler,Nothing}}(nothing)

function _check_live()
    s = _LIVE_SCHEDULER[]
    s === nothing && error("No live scheduler — call start_live!() or live() first.")
    return s
end

d!(slot::Symbol, p::Pattern) = set_pattern!(_check_live(), slot, p)
unset!(slot::Symbol)         = unset_pattern!(_check_live(), slot)
hush_all!()                  = hush!(_check_live())
cps!(x::Real)                = set_cps!(_check_live(), x)

function start_live!(; host::AbstractString = "127.0.0.1",
                       port::Integer = 57120,
                       cps::Real = 0.5,
                       lookahead::Real = 0.05,
                       plugins::Bool = true)
    if _LIVE_SCHEDULER[] !== nothing
        @warn "A live session is already running — returning the existing scheduler."
        return _LIVE_SCHEDULER[]
    end
    client = OSCClient(host, port)
    sched  = Scheduler(client; cps, lookahead)
    _LIVE_SCHEDULER[] = sched
    start!(sched)
    plugins && _load_plugins()
    return sched
end

function stop_live!()
    s = _LIVE_SCHEDULER[]
    s === nothing && return nothing
    stop!(s); hush!(s); _LIVE_SCHEDULER[] = nothing
    return nothing
end

restart_live!(; kwargs...) = (stop_live!(); start_live!(; kwargs...))

"""
    _ressac_app!(m::LiveModel)

Custom replacement for `TUI.app` whose poll is non-blocking and whose
inter-frame wait uses Julia's `sleep` (which yields to other tasks).

Why we don't use `TUI.app`: it calls `Crossterm.poll(wait)` which is a
`ccall` to libCrossterm without a `gc_safe` annotation. While that ccall
is blocked, Julia's runtime can't safepoint, which prevents any other
`Threads.@spawn`-ed task from making progress. In Ressac that includes
the scheduler thread — so events never ship, you hear silence, and
`events_shipped` stays at 0. This loop polls with a 0 timeout (returns
immediately whether or not there's an event) and falls back to
`sleep(1/60)` between frames, which is a yielding sleep.
"""
function _ressac_app!(m::LiveModel; frame_period::Float64 = 1/60)
    TUI.tui(; mouse = true) do
        t = TUI.Terminal(; wait = 0.0)
        TUI.init!(m, t)
        # Idle frame budget: when no input event lands in the last
        # `idle_period` seconds, skip the render to keep CPU low and the
        # main thread responsive to the next keystroke. We still render
        # every `idle_period` for animation (cycle indicator etc.).
        idle_period = 1/30
        last_render = 0.0
        while !m.quit
            try
                # Drain ALL pending events in one go. Mouse-Moved / Drag
                # events arrive at the terminal's refresh rate (often
                # >100 Hz) — processing one per frame backlogged the queue
                # and made every render lag behind by seconds. Drain
                # everything, then render at most once. Track whether any
                # render-worthy event landed.
                render_needed = false
                while true
                    evt = TUI.try_get_event(t)
                    evt === nothing && break
                    TUI.update!(m, evt)
                    noisy = evt isa TUI.MouseEvent &&
                            (evt.data.kind == "Moved" ||
                             startswith(evt.data.kind, "Drag"))
                    render_needed = render_needed || !noisy
                end
                if render_needed
                    TUI.render(t, m)
                    TUI.draw(t)
                    last_render = time()
                elseif (time() - last_render) >= idle_period
                    TUI.render(t, m)
                    TUI.draw(t)
                    last_render = time()
                end
            catch err
                _push_log!(m, "[ERROR] frame: $(sprint(showerror, err))")
            end
            sleep(frame_period)
        end
    end
    return nothing
end

"""
    live(; host, port, cps, lookahead)

Boot the Tachikoma-based TUI on top of an active (or freshly-started)
scheduler. This used to call into the TerminalUserInterfaces.jl
LiveModel app; switched to the new Tachikoma RessacApp on the SP13
migration. The legacy LiveModel/_ressac_app! code stays in-tree for
now while the rest of the features are ported over.
"""
function live(; host::AbstractString = "127.0.0.1",
                port::Integer = 57120,
                cps::Real = 0.5,
                lookahead::Real = 0.05)
    existed = _LIVE_SCHEDULER[] !== nothing
    sched = existed ? _LIVE_SCHEDULER[] : start_live!(; host, port, cps, lookahead)
    cfg = _load_ressac_config!()
    _apply_theme!(cfg.theme)
    # Bring the Synth DSL into Main's namespace so pattern evals can
    # use saw/rlpf/lfo/@synth/... without an explicit `using`. Done
    # once per `live()` call; idempotent.
    try
        Core.eval(Main, :(using Ressac.SynthDSL))
    catch
    end
    try
        Tachikoma.app(RessacApp(; scheduler=sched); fps=cfg.fps)
    finally
        # Always free SC voices on exit — drones with auto_env=false
        # would otherwise keep playing after Ressac closes. Cheap nuke
        # via /ressac/panic.
        try
            send_osc(sched.osc, encode(OSCMessage("/ressac/panic", Any[])))
        catch
        end
        existed || stop_live!()
    end
    return nothing
end
