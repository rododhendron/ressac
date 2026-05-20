# Live-coding entry points used by the TUI. All routes go through
# `_route_to_slot!` which inspects `_EVAL_MODE` to choose between immediate
# `set_pattern!` and deferred `schedule_pattern!`. The TUI sets the mode
# before `Core.eval(Main, …)` and restores it in a `finally`.

const _EVAL_MODE = Ref{Tuple{Symbol,Int}}((:immediate, 0))

_current_cycle(s::Scheduler) = (time() - s.t_start) * s.cps

"""
    _route_to_slot!(slot::Symbol, p::Pattern)

Install `p` at `slot` either immediately or at +N cycles, depending on
`_EVAL_MODE[]`. Called by the `@d1`..`@d64` macros.
"""
function _route_to_slot!(slot::Symbol, p::Pattern)
    sched = _check_live()
    mode, n = _EVAL_MODE[]
    if mode === :immediate
        set_pattern!(sched, slot, p)
    else
        target = Rational{Int64}(ceil(Int, _current_cycle(sched)) + n)
        schedule_pattern!(sched, slot, p, target)
    end
    return nothing
end

"""
    _route_to_slot!(slot::Symbol)

No-body form: unset the slot. Always immediate (musical "cut" doesn't
need to wait for a cycle boundary).
"""
function _route_to_slot!(slot::Symbol)
    unset_pattern!(_check_live(), slot)
    return nothing
end
