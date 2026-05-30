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
    live(; host, port, cps, lookahead)

Boot the Tachikoma-based TUI on top of an active (or freshly-started)
scheduler. The legacy `_ressac_app!(::LiveModel)` loop was removed in
the phase-3 LiveModel cleanup — `Tachikoma.app(RessacApp(...))` is now
the single entry point.
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
    app = RessacApp(; scheduler=sched)
    # Sub-project 10: restore the last persisted workspace layout if
    # any. Wrapped so a corrupted file doesn't block boot — the
    # default workspace fallback handles the empty/error case.
    try
        load_layout!(app.workspaces, _default_layout_path())
    catch err
        @warn "Failed to load layout" exception=err
    end
    _ensure_default_workspace!(app)
    try
        Tachikoma.app(app; fps=cfg.fps)
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
