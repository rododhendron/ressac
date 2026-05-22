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
                       lookahead::Real = 0.05)
    if _LIVE_SCHEDULER[] !== nothing
        @warn "A live session is already running — returning the existing scheduler."
        return _LIVE_SCHEDULER[]
    end
    client = OSCClient(host, port)
    sched  = Scheduler(client; cps, lookahead)
    _LIVE_SCHEDULER[] = sched
    start!(sched)
    return sched
end

function stop_live!()
    s = _LIVE_SCHEDULER[]
    s === nothing && return nothing
    stop!(s); hush!(s); _LIVE_SCHEDULER[] = nothing
    return nothing
end

restart_live!(; kwargs...) = (stop_live!(); start_live!(; kwargs...))

function live(; host::AbstractString = "127.0.0.1",
                port::Integer = 57120,
                cps::Real = 0.5,
                lookahead::Real = 0.05)
    existed = _LIVE_SCHEDULER[] !== nothing
    sched = existed ? _LIVE_SCHEDULER[] : start_live!(; host, port, cps, lookahead)
    try
        TUI.app(LiveModel(; scheduler=sched))
    finally
        existed || stop_live!()
    end
    return nothing
end
