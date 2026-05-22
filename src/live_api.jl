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
    _route_to_slot!(slot::Symbol, s::AbstractString)

String form: parse as mini-notation, then route as a `Pattern`. So both
`@d1 p"bd hh"` and `@d1 "bd hh"` work — the latter is what you get if
you forget the `p` prefix.
"""
function _route_to_slot!(slot::Symbol, s::AbstractString)
    return _route_to_slot!(slot, parse_minino(String(s)))
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

# Generate @d1..@d64. Each expands to a `_route_to_slot!(:dN, body)` call,
# or `_route_to_slot!(:dN)` when called with no body.
for n in 1:64
    macro_name = Symbol("d", n)
    slot_name  = Symbol("d", n)
    @eval begin
        macro $(macro_name)(expr)
            return Expr(:call, GlobalRef(@__MODULE__, :_route_to_slot!),
                        QuoteNode($(QuoteNode(slot_name))), esc(expr))
        end
        macro $(macro_name)()
            return Expr(:call, GlobalRef(@__MODULE__, :_route_to_slot!),
                        QuoteNode($(QuoteNode(slot_name))))
        end
    end
end
