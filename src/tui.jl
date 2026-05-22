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
    TUI.tui() do
        t = TUI.Terminal(; wait = 0.0)
        TUI.init!(m, t)
        while !m.quit
            # Catch any per-frame exception (string-indexing surprises,
            # widget render bugs, etc.) and log it instead of crashing
            # the session. A live performer should never lose state to
            # a stray multi-byte keystroke.
            try
                evt = TUI.try_get_event(t)
                evt !== nothing && TUI.update!(m, evt)
                TUI.render(t, m)
                TUI.draw(t)
            catch err
                _push_log!(m, "[ERROR] frame: $(sprint(showerror, err))")
            end
            sleep(frame_period)
        end
    end
    return nothing
end

function live(; host::AbstractString = "127.0.0.1",
                port::Integer = 57120,
                cps::Real = 0.5,
                lookahead::Real = 0.05)
    existed = _LIVE_SCHEDULER[] !== nothing
    sched = existed ? _LIVE_SCHEDULER[] : start_live!(; host, port, cps, lookahead)
    try
        _ressac_app!(LiveModel(; scheduler=sched))
    finally
        existed || stop_live!()
    end
    return nothing
end
