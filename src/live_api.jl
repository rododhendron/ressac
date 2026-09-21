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

"""
    _route_to_slot!(slot::Symbol, sym::Symbol)

Sample/synth name form: `@d1 :acid303` lifts to `pure(:acid303)`.
Lets users skip the explicit `pure()` wrap when they just want a
single named sound on a slot — matches the snippet library
convention `@d1 :name |> n(p"…")`.
"""
function _route_to_slot!(slot::Symbol, sym::Symbol)
    return _route_to_slot!(slot, pure(sym))
end

"""
    _route_to_slot!(slot::Symbol, f::Function)

Forme « contrôle seul » : `@d1 n("0 3 7")` ou `@d1 n "0 3 7"`. La fermeture
est appliquée à la source par défaut (`_DEFAULT_SOUND[]`, un pattern d'un
événement par cycle), comme si l'on avait écrit `@d1 :superpiano |> n(...)`.
"""
_route_to_slot!(slot::Symbol, f::Function) = _route_to_slot!(slot, _lift_head(f))

"""
    _DEFAULT_SOUND

Son utilisé quand une ligne ne fixe que des contrôles (`@d1 n "0 2 4"`).
`_DEFAULT_SOUND[] = :supersaw` pour changer.
"""
const _DEFAULT_SOUND = Ref{Symbol}(:superpiano)
_default_source() = pure(ControlMap(:s => _DEFAULT_SOUND[]))

# Tête de chaîne : une fermeture de contrôle (`n("0 2")`) devient un pattern.
_lift_head(f::Function) = f(_default_source())
_lift_head(x) = x

# ---------------------------------------------------------------------------
# Sucre Tidal : `@d1 n "0 2 4" |> s "piano" |> fast 2`
# ---------------------------------------------------------------------------
#
# Julia découpe les arguments d'une macro sur les espaces :
#   @d1 n "0 2" |> s "bd" |> fast 2   →   (n, "0 2" |> s, "bd" |> fast, 2)
# On aplatit les chaînes `|>` de chaque argument en une suite de jetons,
# on regroupe entre deux pipes, et chaque groupe `f a b` devient un appel :
#   * groupe de tête : `f a` → f(a) ; `f a b … x` → f(a, b, …)(x)
#     (`every 4 rev "bd"` → every(4, rev)("bd")) ;
#   * groupes suivants : `f a b` → f(a, b) (`fast 2` → fast(2)).
# Un groupe d'un seul jeton est laissé tel quel. La tête passe par
# `_lift_head` pour qu'un simple `n "0 2"` sonne.

_flatten_pipe!(out::Vector{Any}, ex) = (push!(out, ex); out)
function _flatten_pipe!(out::Vector{Any}, ex::Expr)
    if ex.head === :call && length(ex.args) == 3 && ex.args[1] === :|>
        _flatten_pipe!(out, ex.args[2])
        push!(out, :|>)
        _flatten_pipe!(out, ex.args[3])
    else
        push!(out, ex)
    end
    return out
end

function _sugar_group(tokens::Vector{Any}, head::Bool)
    length(tokens) == 1 && return tokens[1]
    f = tokens[1]
    if head
        length(tokens) == 2 && return Expr(:call, f, tokens[2])
        return Expr(:call, Expr(:call, f, tokens[2:end-1]...), tokens[end])
    end
    return Expr(:call, f, tokens[2:end]...)
end

function _tidal_sugar(args)
    tokens = Any[]
    for a in args
        _flatten_pipe!(tokens, a)
    end
    groups = Vector{Any}[Any[]]
    for t in tokens
        t === :|> ? push!(groups, Any[]) : push!(groups[end], t)
    end
    any(isempty, groups) && throw(ArgumentError("pipe `|>` sans opérande"))
    ex = Expr(:call, GlobalRef(@__MODULE__, :_lift_head), _sugar_group(groups[1], true))
    for g in groups[2:end]
        ex = Expr(:call, :|>, ex, _sugar_group(g, false))
    end
    return ex
end

# Generate @d1..@d64. Each expands to a `_route_to_slot!(:dN, body)` call,
# or `_route_to_slot!(:dN)` when called with no body.
for n in 1:64
    macro_name = Symbol("d", n)
    slot_name  = Symbol("d", n)
    @eval begin
        macro $(macro_name)(args...)
            isempty(args) && return Expr(:call, GlobalRef(@__MODULE__, :_route_to_slot!),
                                         QuoteNode($(QuoteNode(slot_name))))
            return Expr(:call, GlobalRef(@__MODULE__, :_route_to_slot!),
                        QuoteNode($(QuoteNode(slot_name))), esc(_tidal_sugar(collect(args))))
        end
    end
end
