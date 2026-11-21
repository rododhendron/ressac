import Base: cat, stack

"""
    pure(v) -> Pattern{T}

The pattern that emits `v` once per cycle, with arc `[n, n+1)` for each
integer `n`.

```julia
julia> query(pure(:bd), 0, 2)
2-element Vector{Event{Symbol}}:
 Event{Symbol}(0//1, 1//1, :bd)
 Event{Symbol}(1//1, 2//1, :bd)
```
"""
function pure(v::T) where {T}
    Pattern{T}((s::Rational, e::Rational) -> begin
        events = Event{T}[]
        n_start = floor(Int, s)
        n_stop  = ceil(Int, e)
        for n in n_start:(n_stop - 1)
            nat_start = Rational{Int64}(n)
            # Only emit when the NATURAL onset is in the query window.
            # Don't clip on the left — a clipped left edge would make
            # the scheduler treat the fragment as a fresh onset (and
            # fire again), which was the `slow(2, pure(:bd))` bug.
            # The natural stop overflows past `e` is fine: the scheduler
            # cares about start, downstream consumers clip on intersect.
            if s <= nat_start < e
                push!(events, Event{T}(nat_start, Rational{Int64}(n + 1), v))
            end
        end
        events
    end,
    # Tenue : chaque cycle touché par la fenêtre.
    (s::Rational, e::Rational) ->
        Event{T}[Event{T}(Rational{Int64}(n), Rational{Int64}(n + 1), v) for n in _cycles(s, e)])
end

"""
    silence(T) -> Pattern{T}

The empty pattern for value type `T`. Useful as a placeholder when wiring
slots and for algebraic identities (`stack(p, silence(T)) ≡ p`).
"""
silence(::Type{T}) where {T} =
    Pattern{T}((_s::Rational, _e::Rational) -> Event{T}[],
               (_s::Rational, _e::Rational) -> Event{T}[])

"""
    _as_pattern(p) -> Pattern

Promote any of the three forms the user might type into a Pattern:

  * `AbstractString` → `parse_minino(s)`. Lets users write
    `@d1 "bd hh sn hh" |> gain(0.5)` without the `p"…"` prefix.
  * `Symbol`        → `pure(s)`. Already-supported shortcut for
    bare-name patterns like `@d1 :bd |> n(p"0 3 5")`.
  * `Pattern`       → identity.

Used by every combinator's curried form (`gain(x)`, `jux(f)`,
`every(n, f)`, …) so the lifts stay consistent.
"""
_as_pattern(p::Pattern) = p
_as_pattern(p::Symbol)  = pure(p)
_as_pattern(p::AbstractString) = parse_minino(String(p))
# Un nombre isolé est un pas ; une liste ou un range Julia devient une
# séquence d'un cycle : `n(0:7)`, `n([0, 3, 7])`, `lpf(2 .^ (7:12))`.
_as_pattern(x::Real) = pure(Symbol(string(x)))
_as_pattern(xs::AbstractVector) = isempty(xs) ? silence(Symbol) : seq([_as_pattern(x) for x in xs])
_as_pattern(r::AbstractRange) = _as_pattern(collect(r))

"""
    geom(départ, arrivée, n) -> Vector{Float64}

Suite géométrique de `n` valeurs de `départ` à `arrivée` — l'échelle
naturelle des fréquences : `lpf(geom(200, 6000, 8))`. La version
linéaire est `range(200, 6000, length = 8)` de Julia.
"""
function geom(a::Real, b::Real, n::Integer)
    n > 0 || throw(ArgumentError("geom : n > 0"))
    (a > 0 && b > 0) || throw(ArgumentError("geom : bornes strictement positives"))
    n == 1 && return [float(a)]
    r = (b / a)^(1 / (n - 1))
    return [float(a) * r^(i - 1) for i in 1:n]
end

"""
    fast(n, p) -> Pattern{T}

Compress time by factor `n`: events that occupied one cycle in `p` now occupy
`1/n` cycle. `fast(2, p)` plays `p` at twice the speed.

Throws `ArgumentError` if `n == 0`.
"""
function fast(n::Real, p::Pattern{T}) where {T}
    n_rat = _to_rat(n)
    iszero(n_rat) && throw(ArgumentError("fast factor cannot be zero"))
    scaled(evs) = Event{T}[Event{T}(ev.start / n_rat, ev.stop / n_rat, ev.value) for ev in evs]
    Pattern{T}((s::Rational, e::Rational) -> scaled(p(s * n_rat, e * n_rat)),
               (s::Rational, e::Rational) -> scaled(_held(p, s * n_rat, e * n_rat)))
end

"""
    fast(n::Real) -> (Pattern -> Pattern)

Curried form: `fast(n)(p) == fast(n, p)`. Lets `p |> fast(n)` thread the
pattern as the right-hand arg under Julia's native `|>`.
"""
fast(n::Real) = x -> fast(n, _as_pattern(x))

"""
    fast(facteurs, p) / p |> fast(facteurs)

Facteur patterné, comme Tidal : `fast("<1 2 4>")` change de vitesse à
chaque cycle. Le facteur est lu au début de chaque cycle. Même chose
pour `slow` et `hurry`.
"""
fast(np::Pattern, p::Pattern) = _per_cycle_factor(fast, np, p)
fast(np::Pattern) = x -> fast(np, _as_pattern(x))
fast(np::AbstractString) = x -> fast(parse_minino(String(np)), _as_pattern(x))
fast(np::AbstractString, p) = fast(parse_minino(String(np)), _as_pattern(p))

# Applique `f(facteur, p)` cycle par cycle, le facteur venant d'un pattern.
function _per_cycle_factor(f, np::Pattern, p::Pattern)
    # `hurry` renvoie un ControlPattern même sur un Pattern{Symbol} :
    # on prend le type de sortie sur un essai à facteur 1.
    T = typeof(f(1, p)).parameters[1]
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for cyc in _cycles(s, e)
            a = max(Rational{Int64}(cyc), s); b = min(Rational{Int64}(cyc + 1), e)
            a < b || continue
            v = _value_at(np, Rational{Int64}(cyc))
            v === nothing && continue
            r = _resolve_value(v)
            (r isa Real && r > 0) || continue
            append!(out, f(r, p)(a, b))
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end

"""
    slow(n, p) -> Pattern{T}

Dilate time by factor `n`. Equivalent to `fast(1/n, p)`.
"""
function slow(n::Real, p::Pattern{T}) where {T}
    iszero(n) && throw(ArgumentError("slow factor cannot be zero"))
    fast(inv(_to_rat(n)), p)
end

"""
    slow(n::Real) -> (Pattern -> Pattern)

Curried form: `slow(n)(p) == slow(n, p)`.
"""
slow(n::Real) = x -> slow(n, _as_pattern(x))
slow(np::Pattern, p::Pattern) = _per_cycle_factor(slow, np, p)
slow(np::Pattern) = x -> slow(np, _as_pattern(x))
slow(np::AbstractString) = x -> slow(parse_minino(String(np)), _as_pattern(x))
slow(np::AbstractString, p) = slow(parse_minino(String(np)), _as_pattern(p))

"""
    density(n, p)

Alias of [`fast`](@ref). Provided for TidalCycles compatibility.
"""
const density = fast

"""
    rev(p) -> Pattern{T}

Reverse the order of events within each cycle.

**Phase-1 limitation**: assumes each event sits inside a single cycle.
Events that span cycle boundaries (none of our current combinators produce
those) will be reversed using their `floor(start)` cycle, which may not be
intuitive. We'll lift this restriction when adding `compound` events.
"""
function rev(p::Pattern{T}) where {T}
    Pattern{T}((s::Rational, e::Rational) -> begin
        # Chaque cycle est retourné sur lui-même : tout ce qui y est tenu
        # (commencé là ou avant) est réfléchi autour de son milieu, créneau
        # entier, et compte s'il commence alors dans ce cycle — et dans la
        # fenêtre. Un événement à cheval sur deux cycles est donc réfléchi
        # dans chacun, comme les fragments de Tidal, sans qu'un fragment
        # soit jamais pris pour une attaque.
        out = Event{T}[]
        for n in _cycles(s, e)
            c0 = Rational{Int64}(n); c1 = c0 + 1
            mirror = c0 + c1
            for ev in _held(p, c0, c1)
                new_start = mirror - ev.stop
                (c0 <= new_start < c1 && s <= new_start < e) || continue
                push!(out, Event{T}(new_start, mirror - ev.start, ev.value))
            end
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end

# ── Un pattern et sa version transformée ─────────────────────────────
# `every`, `lastOf`, `sometimesBy`, `whenmod`, `chunk`, `off`… jouent tantôt
# `p`, tantôt `f(p)`. Deux règles communes, tenues ici une fois pour toutes :
#   • `f(p)` est construit UNE fois, à la construction — jamais à la requête
#     (une erreur dans `f` se lit à l'évaluation, pas dans le scheduler) ;
#   • `f` peut changer le type des valeurs (`gain(0.5)` fait d'un pattern de
#     noms un pattern de contrôles) : les deux sont alors montés au même type.

# Liste de patterns homogène : même T, sinon tout le monde monte en ControlMap.
function _same_patterns(xs)
    ps = Any[_as_pattern(x) for x in xs]
    isempty(ps) && throw(ArgumentError("il faut au moins un pattern"))
    T = typeof(ps[1]).parameters[1]
    all(p -> p isa Pattern{T}, ps) && return Pattern{T}[p for p in ps]
    return ControlPattern[_lift_to_control(p) for p in ps]
end


# Applique `f` sur les cycles où `test(cycle)` est vrai.
function _when_cycle(test, f, p0::Pattern)
    p, fp = _same_patterns((p0, f(p0)))
    T = typeof(p).parameters[1]
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for cyc in _cycles(s, e)
            a = max(Rational{Int64}(cyc), s); b = min(Rational{Int64}(cyc + 1), e)
            a < b || continue
            append!(out, (test(cyc) ? fp : p)(a, b))
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end


"""
    _rand01(key, seed = 0) -> Float64 dans [0, 1)

Le tirage de tous les combinateurs aléatoires : une fonction du temps (ou du
cycle), donc reproductible d'un rendu à l'autre. Deux combinateurs sur la
même grille tirent les mêmes nombres — comme dans Tidal — sauf si on leur
donne des `seed` différents : `degradeBy(0.5; seed = 1)`.
"""
_rand01(key, seed::Integer = 0) = seed == 0 ? _u01(key) : _u01(key, seed)

"""
    every(n, f, p) -> Pattern

Apply transformation `f` to `p` on every `n`-th cycle (cycles `0, n, 2n, ...`);
play `p` unchanged on the other cycles.

`f` is called **once**, at construction time, to build the transformed pattern.
It may change the value type (`every(2, gain(0.5), p"bd")`).
"""
function every(n::Int, f, p::Pattern)
    n > 0 || throw(ArgumentError("every needs n > 0"))
    return _when_cycle(cyc -> mod(cyc, n) == 0, f, p)
end

"""
    every(n::Int, f) -> (Pattern -> Pattern)

Curried form: `every(n, f)(p) == every(n, f, p)`.
"""
every(n::Int, f) = x -> every(n, f, _as_pattern(x))

"""
    stack(p, q, …) -> Pattern

Layer patterns in parallel: every event of every input pattern is emitted.
The first argument is a pattern; the others may be patterns, strings or
names. Mixed kinds are fine — `stack(p"bd*4", "hh*8" |> gain(0.6))` — they
are all lifted to the same value type. Extends `Base.stack`.
"""
stack(p::Pattern, q, rest...) = _stack(_same_patterns((p, q, rest...)))

"""
    stack(q) -> (Pattern -> Pattern)

Curried form, for the pipe: `p |> stack(q)` is `stack(p, q)`.
"""
stack(q::Pattern) = p -> stack(_as_pattern(p), q)

# L'empilement lui-même, sur une liste déjà homogène (voir `_same_patterns`).
# Le code interne passe par ici, jamais par `stack(liste...)` : avec un seul
# élément, la forme publique est la forme au pipe et rendrait une fonction.
function _stack(ps::AbstractVector{<:Pattern})
    isempty(ps) && throw(ArgumentError("stack needs at least one pattern"))
    length(ps) == 1 && return ps[1]
    T = typeof(ps[1]).parameters[1]
    gather(q, s, e) = begin
        out = Event{T}[]
        for p in ps
            append!(out, q(p, s, e))
        end
        sort!(out, by = ev -> ev.start)
        out
    end
    Pattern{T}((s::Rational, e::Rational) -> gather((p, a, b) -> p(a, b), s, e),
               (s::Rational, e::Rational) -> gather(_held, s, e))
end

"""
    cat(ps::Vector{<:Pattern{T}}) -> Pattern{T}
    cat(ps::Pattern{T}...)        -> Pattern{T}

Cycle through patterns: cycle 0 plays `ps[1]` over `[0, 1)`, cycle 1 plays
`ps[2]` over `[1, 2)`, …, wrapping around. Each pattern is played as if its
local time started at 0. Extends `Base.cat`.
"""
function cat(ps::Vector{<:Pattern{T}}) where {T}
    isempty(ps) && throw(ArgumentError("cat needs at least one pattern"))
    nps = length(ps)
    Pattern{T}((s::Rational, e::Rational) -> begin
        n_start = floor(Int, s)
        n_stop = ceil(Int, e)
        out = Event{T}[]
        for cyc in n_start:(n_stop - 1)
            a = max(Rational{Int64}(cyc), s)
            b = min(Rational{Int64}(cyc + 1), e)
            a < b || continue
            chosen = ps[mod(cyc, nps) + 1]
            shift = Rational{Int64}(cyc)
            inner_evs = chosen(a - shift, b - shift)
            for ev in inner_evs
                push!(out, Event{T}(ev.start + shift, ev.stop + shift, ev.value))
            end
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end

cat(ps::Vararg{Pattern{T}}) where {T} = cat(collect(ps))

"""
    gate(name::Symbol, p::Pattern{Symbol}) -> Pattern{Symbol}

Substitute `name` for every "hit" event in `p`, drop "silence" events.
Lets you write a long instrument name once and use a short numeric
mask for the rhythm:

```julia
gate(:super808, p"1 0 0 1 0 0 1 0")   # 808 on positions 1, 4, 7
gate(:supersnare, p"~ ~ x ~")          # snare on position 3 only
```

Silence values: `~` (mini-notation primitive), and the symbols `:0`,
`:false`, `:no`, or empty — anything else is treated as a hit.
"""
function gate(name::Symbol, p::Pattern{Symbol})
    Pattern{Symbol}((s::Rational, e::Rational) -> begin
        out = Event{Symbol}[]
        for ev in p(s, e)
            sym_str = String(ev.value)
            sym_str in ("0", "false", "no", "") && continue
            push!(out, Event{Symbol}(ev.start, ev.stop, name))
        end
        out
    end)
end

# Pipe-friendly curried form: `:bd |> gate(p"1 0 1 0")` reads as
# "take :bd, gate it with that mask". Julia's pipe rewrite makes it
# `gate(p"…")(:bd)`, so `gate(p)` has to return a Symbol → Pattern
# function. Same body as the binary call.
gate(p::Pattern{Symbol}) = (name::Symbol) -> gate(name, p)

# Accept a bare string mask: `gate(:s, "1 0 1 0")` is the same as
# `gate(:s, p"1 0 1 0")`. Lets users drop the `p"…"` prefix.
gate(name::Symbol, s::AbstractString) = gate(name, parse_minino(String(s)))
gate(s::AbstractString) = gate(parse_minino(String(s)))

# ---------------------------------------------------------------------------
# Tidal-style transforms — stereo, probability, time-shift
# ---------------------------------------------------------------------------
# These mirror the canonical TidalCycles combinators so users coming
# from Tidal find their muscle memory intact, and so the patterns we
# can express stay competitive with Tidal's expressivity.
#
# `jux`, `juxBy`           : route `f(p)` to right channel via pan
# `off`                    : overlay a time-shifted+transformed copy
# `degrade`, `degradeBy`   : probabilistic event drop (per event)
# `sometimes`, `sometimesBy`, `often`, `rarely` : probabilistic
#                            transform-apply (per cycle)
# `palindrome`             : alternate forward / reverse each cycle
# `iter`                   : rotate the cycle by 1/n each cycle
# `chunk`                  : apply f to one of n equal chunks per cycle
#
# All probabilistic functions seed from a deterministic hash of the
# event start (or cycle index) so a given pattern always produces the
# same output — no surprise jitter between renders.

"""
    jux(f, p) -> Pattern{T}

Stereo split: left channel plays `p` as-is, right channel plays
`f(p)`. Implemented as `stack(p |> pan(0), f(p) |> pan(1))`.
Forces the pattern through ControlMap (a bare Pattern{Symbol} is
lifted into ControlPattern via `pan(0)`).
"""
function jux(f, p)
    p_pat = _as_pattern(p)
    return stack(p_pat |> pan(0.0), f(p_pat) |> pan(1.0))
end
jux(f) = p -> jux(f, p)

"""
    juxBy(amount, f, p) -> Pattern

`jux` with reduced stereo spread. `amount=1` is full L/R, `amount=0`
collapses both copies to center.
"""
function juxBy(amount::Real, f, p)
    p_pat = _as_pattern(p)
    d = 0.5 * float(amount)
    return stack(p_pat |> pan(0.5 - d), f(p_pat) |> pan(0.5 + d))
end
juxBy(amount::Real, f) = p -> juxBy(amount, f, p)

"""
    off(t, f, p) -> Pattern{T}

Overlay `p` with a copy of `f(p)` shifted forward by `t` cycles.
The "shift" is a phase offset: the copy plays t-cycles later within
its own cycle, wrapping at the boundary.
"""
off(t::Real, f, p::Pattern) = _stack(_same_patterns((p, late(t, f(p)))))
off(t::Real, f) = p -> off(t, f, _as_pattern(p))

"""
    degradeBy(prob, p) -> Pattern{T}

Drop each event from `p` with probability `prob` (0..1). The draw is a
function of the event's start, so successive renders produce the same drops —
the groove is repeatable. Two `degradeBy` on the same grid drop the same
events; give them different `seed`s to decorrelate them:
`p |> degradeBy(0.5) |> degradeBy(0.5; seed = 1)`.
"""
function degradeBy(prob::Real, p::Pattern{T}; seed::Integer = 0) where {T}
    pr = clamp(float(prob), 0.0, 1.0)
    Pattern{T}((s::Rational, e::Rational) ->
        Event{T}[ev for ev in p(s, e) if _rand01(ev.start, seed) >= pr])
end
degradeBy(prob::Real; seed::Integer = 0) = p -> degradeBy(prob, _as_pattern(p); seed)

"""
    degrade(p) -> Pattern{T}

Shortcut for `degradeBy(0.5, p)`. Drops half the events at random.
"""
degrade(p; seed::Integer = 0) = degradeBy(0.5, _as_pattern(p); seed)

"""
    sometimesBy(prob, f, p) -> Pattern{T}

Apply transform `f` to `p` with probability `prob` per cycle. The
decision is per cycle (not per event) so a "sometimes faster" treats
the whole cycle uniformly. The draw depends only on the cycle number: every
`sometimes` of the session fires on the same cycles unless given its own
`seed` (`sometimes(rev; seed = 2)`).
"""
function sometimesBy(prob::Real, f, p::Pattern; seed::Integer = 0)
    pr = clamp(float(prob), 0.0, 1.0)
    return _when_cycle(cyc -> _rand01(cyc, seed) < pr, f, p)
end
sometimesBy(prob::Real, f; seed::Integer = 0) = p -> sometimesBy(prob, f, _as_pattern(p); seed)

"""
    sometimes(f, p) — `sometimesBy(0.5, …)`
    often(f, p)     — `sometimesBy(0.75, …)`
    rarely(f, p)    — `sometimesBy(0.25, …)`

All take `seed` like [`sometimesBy`](@ref).
"""
sometimes(f, p; seed::Integer = 0) = sometimesBy(0.5, f, _as_pattern(p); seed)
sometimes(f; seed::Integer = 0)    = p -> sometimes(f, p; seed)
often(f, p; seed::Integer = 0)     = sometimesBy(0.75, f, _as_pattern(p); seed)
often(f; seed::Integer = 0)        = p -> often(f, p; seed)
rarely(f, p; seed::Integer = 0)    = sometimesBy(0.25, f, _as_pattern(p); seed)
rarely(f; seed::Integer = 0)       = p -> rarely(f, p; seed)

"""
    palindrome(p) -> Pattern{T}

Alternate forward / reverse each cycle: cycle 0 = `p`, cycle 1 =
`rev(p)`, cycle 2 = `p`, …. Equivalent to `every(2, rev, p)` but
clearer at the call site.
"""
palindrome(p::Pattern{T}) where {T} = every(2, rev, p)
palindrome(p::Symbol) = palindrome(pure(p))

"""
    iter(n, p) -> Pattern{T}

Rotate the cycle by `1/n` each successive cycle: cycle 0 = `p`,
cycle 1 = `p` shifted forward by `1/n`, cycle 2 = by `2/n`, etc.
Wraps every `n` cycles.
"""
function iter(n::Int, p::Pattern{T}) where {T}
    n >= 1 || throw(ArgumentError("iter step must be ≥ 1"))
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        n_start = floor(Int, s)
        n_stop  = ceil(Int, e)
        for cyc in n_start:(n_stop - 1)
            a = max(Rational{Int64}(cyc), s)
            b = min(Rational{Int64}(cyc + 1), e)
            a < b || continue
            shift = Rational{Int64}(cyc, n)
            base = Rational{Int64}(cyc)
            inner = p(a - base + shift, b - base + shift)
            for ev in inner
                push!(out,
                    Event{T}(ev.start + base - shift,
                             ev.stop  + base - shift,
                             ev.value))
            end
        end
        out
    end)
end
iter(n::Int) = p -> iter(n, _as_pattern(p))

"""
    chunk(n, f, p) -> Pattern{T}

Split each cycle into `n` equal chunks; apply `f` to a different
chunk per cycle, leaving the others as-is. Cycles through chunks
0..n-1 then repeats.
"""
chunk(n::Int, f, p::Pattern) = _chunked(n, f, p, cyc -> mod(cyc, n))

# `chunk` et `chunkBack` : le cycle en `n` morceaux, `f` sur celui que
# désigne `active(cycle)`.
function _chunked(n::Int, f, p0::Pattern, active)
    n >= 1 || throw(ArgumentError("chunk count must be ≥ 1"))
    p, fp = _same_patterns((p0, f(p0)))
    T = typeof(p).parameters[1]
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for cyc in _cycles(s, e)
            base = Rational{Int64}(cyc)
            k_active = active(cyc)
            for k in 0:(n - 1)
                a = max(base + Rational{Int64}(k, n), s); b = min(base + Rational{Int64}(k + 1, n), e)
                a < b || continue
                append!(out, (k == k_active ? fp : p)(a, b))
            end
        end
        out
    end)
end
chunk(n::Int, f) = p -> chunk(n, f, _as_pattern(p))

# ---------------------------------------------------------------------------
# Sprint 1 — Tidal/Strudel parity batch
# ---------------------------------------------------------------------------

"""
    iterBack(n, p) -> Pattern{T}

Like [`iter`](@ref) but rotates in the opposite direction. Cycle 0
plays unshifted, cycle 1 starts at the LAST 1/n slice (effectively
shifting by -1/n), cycle 2 by -2/n, etc.
"""
function iterBack(n::Int, p::Pattern{T}) where {T}
    n > 0 || throw(ArgumentError("iterBack needs n > 0"))
    iter(n, rev(p)) |> rev   # reverse twice for backward rotation
end
iterBack(n::Int) = p -> iterBack(n, _as_pattern(p))

"""
    lastOf(n, f, p) -> Pattern{T}

Apply `f` to `p` on cycles `n-1, 2n-1, 3n-1, …` — i.e. every nth
cycle starting from the LAST one in the period. Counterpart of
[`every`](@ref) (which fires on cycles `0, n, 2n, …`). Same as
Tidal's `lastOf`.
"""
function lastOf(n::Int, f, p::Pattern)
    n > 0 || throw(ArgumentError("lastOf needs n > 0"))
    return _when_cycle(cyc -> mod(cyc + 1, n) == 0, f, p)
end
lastOf(n::Int, f) = p -> lastOf(n, f, _as_pattern(p))

"`firstOf` — TidalCycles alias for `every` (cycle 0, n, 2n, …)."
const firstOf = every

"""
    early(t, p) -> Pattern{T}

Shift `p` `t` cycles EARLIER (`t > 0` brings events forward in
time). Reciprocal of [`late`](@ref).
"""
function early(t::Real, p::Pattern{T}) where {T}
    dt = _to_rat(t)
    shifted(evs) = Event{T}[Event{T}(ev.start - dt, ev.stop - dt, ev.value) for ev in evs]
    Pattern{T}((s::Rational, e::Rational) -> shifted(p(s + dt, e + dt)),
               (s::Rational, e::Rational) -> shifted(_held(p, s + dt, e + dt)))
end
early(t::Real) = p -> early(t, _as_pattern(p))

"""
    late(t, p) -> Pattern{T}

Shift `p` `t` cycles LATER. Equivalent to `early(-t, p)`.
"""
late(t::Real, p) = early(-_to_rat(t), _as_pattern(p))
late(t::Real)    = p -> late(t, _as_pattern(p))

"""
    frappes(instants...; cycles = 1) -> Pattern
    frappes(p, instants...; cycles = 1)

Un pattern d'instants exacts : `p` est frappé à chaque instant (en cycles
depuis le début de la boucle), et le tout se répète tous les `cycles`
cycles — une longueur libre, pas forcément entière. Chaque frappe dure
jusqu'à la suivante. Les frappes prennent tour à tour les valeurs que `p`
joue sur un cycle : `p"bd sn" |> frappes(0, 0.4, 1.1; cycles = 1.5)` fait
bd, sn, bd. C'est ce qu'écrit la boucle (`Espace o`).
"""
function frappes(p::Pattern{T}, instants::Real...; cycles::Real = 1) where {T}
    len = _to_rat(round(Float64(cycles); digits = 6))
    len > 0 || throw(ArgumentError("frappes : cycles doit être > 0"))
    ts = sort!(unique!(Rational{Int64}[mod(_to_rat(round(Float64(t); digits = 6)), len) for t in instants]))
    isempty(ts) && return Pattern{T}((s::Rational, e::Rational) -> Event{T}[])
    n = length(ts)
    function query(s::Rational, e::Rational)
        out = Event{T}[]
        for k in floor(Int, s / len):floor(Int, e / len)
            base = k * len
            base >= e && break
            vals = nothing
            for (i, t) in enumerate(ts)
                start = base + t
                s <= start < e || continue
                if vals === nothing
                    evs = sort!(collect(p(Rational{Int64}(k), Rational{Int64}(k + 1))); by = ev -> ev.start)
                    vals = T[ev.value for ev in evs]
                end
                isempty(vals) && break
                stop = base + (i < n ? ts[i + 1] : len + ts[1])
                push!(out, Event{T}(start, stop, vals[mod1(i, length(vals))]))
            end
        end
        return out
    end
    return Pattern{T}(query)
end
frappes(instants::Real...; cycles::Real = 1) = p -> frappes(_as_pattern(p), instants...; cycles = cycles)

"""
    ply(n, p) -> Pattern{T}

Repeat each event `n` times within its own slot (Tidal's `ply`).
`ply(3, p"bd sn")` plays `bd bd bd sn sn sn` over one cycle.
"""
function ply(n::Int, p::Pattern{T}) where {T}
    n > 0 || throw(ArgumentError("ply needs n > 0"))
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        n_rat = Rational{Int64}(n)
        # Les répétitions d'un événement long tombent dans les cycles
        # suivants : on part de ce qui est tenu, et chaque répétition compte
        # là où elle commence.
        for ev in _held(p, s, e)
            width = ev.stop - ev.start
            slice = width / n_rat
            for i in 0:(n - 1)
                a = ev.start + slice * i
                b = i == n - 1 ? ev.stop : ev.start + slice * (i + 1)
                s <= a < e && push!(out, Event{T}(a, b, ev.value))
            end
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end
ply(n::Int) = p -> ply(n, _as_pattern(p))

"""
    run(n) -> Pattern{Int}

A pattern that fires the sequence `0, 1, …, n-1` once per cycle,
each event of equal length. Useful for `n(run(8))` to iterate
through sample variants.
"""
function run(n::Int)
    n > 0 || throw(ArgumentError("run needs n > 0"))
    Pattern{Int}((s::Rational, e::Rational) -> begin
        n_start = floor(Int, s)
        n_stop  = ceil(Int, e)
        out = Event{Int}[]
        n_rat = Rational{Int64}(n)
        for cyc in n_start:(n_stop - 1)
            for i in 0:(n - 1)
                a = Rational{Int64}(cyc) + Rational{Int64}(i) / n_rat
                b = Rational{Int64}(cyc) + Rational{Int64}(i + 1) / n_rat
                a < e && b > s &&
                    push!(out, Event{Int}(max(a, s), min(b, e), i))
            end
        end
        out
    end)
end

"""
    runp(n) -> Pattern{Int}

Exported alias of [`run`](@ref). Same behaviour — fires `0, 1, …, n-1`
once per cycle. Renamed for export to avoid clashing with
`Base.run` (which spawns shell commands).
"""
const runp = run

"""
    choose(xs) -> Pattern{T}

One random pick from `xs` per cycle — a deterministic function of the cycle
number, so the same cycle always makes the same pick.
"""
function choose(xs::AbstractVector{T}) where {T}
    n = length(xs)
    n > 0 || throw(ArgumentError("choose needs at least one element"))
    Pattern{T}((s::Rational, e::Rational) -> begin
        n_start = floor(Int, s)
        n_stop  = ceil(Int, e)
        out = Event{T}[]
        for cyc in n_start:(n_stop - 1)
            # Un événement par cycle, entier, rendu dans la fenêtre de son attaque.
            a = Rational{Int64}(cyc)
            s <= a < e && push!(out, Event{T}(a, a + 1, xs[_pick(n, (cyc, :choose))]))
        end
        out
    end)
end

"""
    seq(xs) -> Pattern{T}

Concatenate `xs` into one cycle (Tidal's `fastcat` / Strudel's
`seq`). Each element gets a 1/n slice. Same as `fast(length(xs), cat(xs))`.
"""
seq(xs::AbstractVector{<:Pattern{T}}) where {T} = fast(length(xs), cat(xs))
seq(xs::Vararg{Pattern}) = seq(collect(xs))

"""
    structPat(bools, p) -> Pattern{T}

Take the *structure* of `bools` (a Pattern{Bool}) and use its
true-events to gate `p`'s values, in order. Each true slot picks
the NEXT value from `p`'s natural unfolding, ignoring its own
timing. Useful when you have a rhythm mask and want to apply it
to a melody source.

Named `structPat` rather than `struct` because `struct` is a
Julia reserved keyword.
"""
function structPat(bools::Pattern{Bool}, p::Pattern{T}) where {T}
    Pattern{T}((s::Rational, e::Rational) -> begin
        b_evs = bools(s, e)
        v_evs = p(s, e)
        out = Event{T}[]
        vi = 1
        for be in b_evs
            be.value || continue   # only fire on true slots
            vi <= length(v_evs) || break
            push!(out, Event{T}(be.start, be.stop, v_evs[vi].value))
            vi += 1
        end
        out
    end)
end
structPat(bools::Pattern{Bool}) = p -> structPat(bools, _as_pattern(p))

# ---------------------------------------------------------------------------
# Sprint 3 — Continuous signals (sine/saw/rand/perlin, range, segment)
# ---------------------------------------------------------------------------
#
# Tidal/Strudel call these "continuous" patterns: not discrete events but
# functions of time, sampled at query time. They're the modulation
# backbone — `set(:cutoff, sine() |> range(400, 4000))` sweeps a filter.
#
# Internally we model them as `Pattern{Float64}` with a query function
# that emits a SINGLE event covering the whole [s, e) arc with the
# value sampled at the arc midpoint. `segment(n, sig)` discretises by
# splitting the cycle into n samples.

"""
    sine() / cosine() / tri() / saw() / square() -> Pattern{Float64}

Continuous waveform patterns, one cycle = one period. **All of them live in
`[0, 1]`**, like Tidal's: `pan(sine())` sweeps the whole stereo field as is,
and `range_pat(lo, hi)` maps any of them (and `rand_pat`, `perlin`, the
`core_maths` curves) onto `[lo, hi]`. `sine` starts at 0.5 and rises, `cosine`
is `sine` a quarter cycle early, `tri` goes 0 → 1 → 0, `saw` 0 → 1,
`square` is 0 then 1.
"""
sine()   = _continuous(t -> (sin(2π * t) + 1) / 2)
cosine() = _continuous(t -> (cos(2π * t) + 1) / 2)
tri()    = _continuous(t -> begin u = mod(t, 1.0); u < 0.5 ? 2u : 2 - 2u end)
saw()    = _continuous(t -> mod(t, 1.0))
square() = _continuous(t -> mod(t, 1.0) < 0.5 ? 0.0 : 1.0)

"""
    rand() -> Pattern{Float64}

Continuous-ish random pattern: deterministic per cycle index but
varying across cycles (so it doesn't freeze on a single value).
Output `[0, 1)`. For discrete sampling use `rand() |> segment(n)`.
"""
function rand_pat()
    _signal((s::Rational, e::Rational) -> begin
        mid = (s + e) / 2
        [Event{Float64}(s, e, _u01((floor(Int, s), Float64(mid), :rand)))]
    end)
end

"""
    perlin() -> Pattern{Float64}

Smoothed-random pattern (cheap 1D value-noise — not true Perlin
but the use-case is identical: slowly-changing random in [0, 1)).
Adjacent cycles' values are interpolated via cosine smoothstep.
"""
function perlin()
    _h(c) = _u01((c, :perlin))
    _signal((s::Rational, e::Rational) -> begin
        mid = Float64((s + e) / 2)
        c0 = floor(Int, mid)
        c1 = c0 + 1
        t  = mid - c0
        # Cosine smoothstep blend.
        u = (1 - cos(π * t)) / 2
        v = _h(c0) * (1 - u) + _h(c1) * u
        [Event{Float64}(s, e, v)]
    end)
end

# Internal: lift `t -> Float64` into a Pattern{Float64} that emits a
# single event covering the query arc, value sampled at the midpoint.
_continuous(f) = _signal((s::Rational, e::Rational) -> begin
    mid = Float64((s + e) / 2)
    [Event{Float64}(s, e, f(mid))]
end)

# Un signal répond à toute fenêtre par un échantillon : sa tenue est sa requête.
_signal(sample) = Pattern{Float64}(sample, sample)

"""
    range_pat(lo, hi, p) -> Pattern{Float64}
    range_pat(lo, hi)    -> (Pattern -> Pattern)

Linearly remap `p` from `[0, 1]` — the range of every signal (`sine`, `saw`,
`rand_pat`, `perlin`…) — onto `[lo, hi]`: 0 gives `lo`, 1 gives `hi`.
`sine() |> range_pat(400, 4000)` sweeps a filter between those two values.
"""
function range_pat(lo::Real, hi::Real, p::Pattern{Float64})
    lo_f = Float64(lo); hi_f = Float64(hi)
    return _mapvals(v -> lo_f + (hi_f - lo_f) * v, p, Float64)
end
range_pat(lo::Real, hi::Real) = p -> range_pat(lo, hi, _as_pattern(p))

"""
    segment(n, p) -> Pattern{Float64}
    segment(n)    -> (Pattern -> Pattern)

Sample a continuous pattern `n` times per cycle, producing `n`
discrete events with the value of `p` at each segment's midpoint.
Converts a continuous signal into a usable event stream.
"""
function segment(n::Int, p::Pattern{T}) where {T}
    n > 0 || throw(ArgumentError("segment needs n > 0"))
    Pattern{T}((s::Rational, e::Rational) -> begin
        n_start = floor(Int, s)
        n_stop  = ceil(Int, e)
        out = Event{T}[]
        n_rat = Rational{Int64}(n)
        for cyc in n_start:(n_stop - 1)
            for i in 0:(n - 1)
                a = Rational{Int64}(cyc) + Rational{Int64}(i) / n_rat
                b = Rational{Int64}(cyc) + Rational{Int64}(i + 1) / n_rat
                a < e && b > s || continue
                evs = p(a, b)
                isempty(evs) && continue
                ca = max(a, s); cb = min(b, e)
                push!(out, Event{T}(ca, cb, evs[1].value))
            end
        end
        out
    end)
end
segment(n::Int) = p -> segment(n, _as_pattern(p))

# ---------------------------------------------------------------------------
# Découpage de samples — chop (striate / striateBy / slice / splice : core_tidal.jl)
# ---------------------------------------------------------------------------

"""
    chop(n, p) -> Pattern{ControlMap}
    chop(n)    -> (Pattern -> Pattern{ControlMap})

Découpe CHAQUE événement de `p` en `n` sous-événements consécutifs qui
lisent chacun la tranche `[i/n, (i+1)/n)` du sample (`:begin` / `:end`
SuperDirt). `striate` fait l'inverse : il joue le pattern `n` fois dans
le cycle, chaque répétition lisant une tranche différente.

```julia
@d1 :amen |> chopp(8)          # 8 morceaux consécutifs par cycle
@d1 :amen |> chopp(16) |> rev  # à l'envers
```
"""
function chop(n::Int, p)
    n > 0 || throw(ArgumentError("chop needs n > 0"))
    cp = _lift_to_control(_as_pattern(p))
    Pattern{ControlMap}((s::Rational, e::Rational) -> begin
        out = Event{ControlMap}[]
        n_rat = Rational{Int64}(n)
        for ev in _held(cp, s, e)
            width = ev.stop - ev.start
            slice = width / n_rat
            for i in 0:(n - 1)
                a = ev.start + slice * i
                b = i == n - 1 ? ev.stop : ev.start + slice * (i + 1)
                a >= s && a < e || continue
                cm = copy(ev.value)
                cm[:begin] = Float32(i) / Float32(n)
                cm[:end]   = Float32(i + 1) / Float32(n)
                push!(out, Event{ControlMap}(a, b, cm))
            end
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end
chop(n::Int) = p -> chop(n, p)

"""
    chopp(n) -> (Pattern -> Pattern{ControlMap})

Alias exporté de [`chop`](@ref) (`Base.chop` existe déjà).
"""
const chopp = chop

# ---------------------------------------------------------------------------
# arp — arpège des accords (événements simultanés), comme Tidal
# ---------------------------------------------------------------------------

# Ordre des indices 1..n pour un mode d'arpège Tidal.
function _arp_order(mode::Symbol, n::Int)
    up = collect(1:n); down = reverse(up)
    conv = Int[]; lo, hi = 1, n
    while lo <= hi
        push!(conv, lo); lo == hi || push!(conv, hi); lo += 1; hi -= 1
    end
    m = String(mode)
    m == "up"            && return up
    m == "down"          && return down
    m == "updown"        && return n <= 1 ? up : vcat(up[1:end-1], down[1:end-1])
    m == "downup"        && return n <= 1 ? up : vcat(down[1:end-1], up[1:end-1])
    m == "up&down"       && return vcat(up, down)
    m == "down&up"       && return vcat(down, up)
    m == "converge"      && return conv
    m == "diverge"       && return reverse(conv)
    m == "disconverge"   && return vcat(conv, reverse(conv)[2:end])
    m == "pinkyup"       && return n <= 1 ? up : vcat([[i, n] for i in 1:(n-1)]...)
    m == "pinkyupdown"   && return n <= 1 ? up : vcat([[i, n] for i in 1:(n-1)]..., [[i, n] for i in (n-1):-1:2]...)
    m == "thumbup"       && return n <= 1 ? up : vcat([[1, i] for i in 2:n]...)
    m == "thumbupdown"   && return n <= 1 ? up : vcat([[1, i] for i in 2:n]..., [[1, i] for i in (n-1):-1:2]...)
    throw(ArgumentError("mode d'arpège inconnu « $m » (up down updown downup up&down down&up converge diverge disconverge pinkyup pinkyupdown thumbup thumbupdown)"))
end

# Hauteur d'un événement pour trier les notes d'un accord.
_arp_key(v::Symbol) = (r = _resolve_note(v); r isa Real ? Float64(r) : 0.0)
_arp_key(v::Real) = Float64(v)
_arp_key(v::AbstractDict) = (x = get(v, :note, get(v, :n, 0)); x isa Real ? Float64(x) : _arp_key(x))
_arp_key(v) = 0.0

"""
    arp(mode, p) / p |> arp(mode)

Arpège : les notes jouées ensemble (même début et même fin — un accord
`c'maj`, un `[0,4,7]`) sont jouées l'une après l'autre dans leur
créneau, dans l'ordre du mode. `mode` : `:up`, `"down"`, ou un pattern
de modes `"<up down>"` (échantillonné au début de chaque accord).
"""
function arp(modes, p::Pattern{T}) where {T}
    mp = _as_pattern(modes)
    Pattern{T}((s::Rational, e::Rational) -> begin
        evs = p(s, e)
        spans = Tuple{Rational{Int64},Rational{Int64}}[]
        groups = Dict{Tuple{Rational{Int64},Rational{Int64}},Vector{Event{T}}}()
        for ev in evs
            k = (ev.start, ev.stop)
            haskey(groups, k) || (push!(spans, k); groups[k] = Event{T}[])
            push!(groups[k], ev)
        end
        sort!(spans, by = first)
        out = Event{T}[]
        for (a, b) in spans
            notes = sort(groups[(a, b)]; by = ev -> _arp_key(ev.value))
            mevs = mp(a, b)
            mode = isempty(mevs) ? :up : Symbol(String(mevs[1].value))
            order = _arp_order(mode, length(notes))
            slice = (b - a) / length(order)
            for (k, idx) in enumerate(order)
                push!(out, Event{T}(a + slice * (k - 1), k == length(order) ? b : a + slice * k, notes[idx].value))
            end
        end
        out
    end)
end
arp(modes) = p -> arp(modes, _as_pattern(p))

# ---------------------------------------------------------------------------
# Tour des fonctions Tidal — rot, hurry, shuffle, scramble, linger, swing,
# whenmod, someCycles, fastGap, compress, zoom, euclid*, superimpose,
# inside/outside, rolled, brak, layer, stut. Cf. docs/wiki/02-patterns.md.
# ---------------------------------------------------------------------------

# Cycles entiers touchés par une fenêtre [s, e).
_cycles(s::Rational, e::Rational) = floor(Int, s):(ceil(Int, e) - 1)
# Un événement « démarre » dans la fenêtre (sémantique onset des patterns).
_onset_in(ev, s, e) = ev.start >= s && ev.start < e
# Valeur de `p` active à l'instant t (l'événement dont le créneau contient t).
function _value_at(p::Pattern, t::Rational)
    ev = _event_at(p, t)
    return ev === nothing ? nothing : ev.value
end

"""
    rot(n, p) / p |> rot(n)

Fait tourner les VALEURS de `n` crans dans chaque cycle, en gardant la
structure rythmique : `"bd hh sn" |> rot(1)` joue `hh sn bd`.
"""
function rot(n::Int, p::Pattern{T}) where {T}
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for cyc in _cycles(s, e)
            a = Rational{Int64}(cyc)
            evs = sort(p(a, a + 1); by = ev -> (ev.start, _arp_key(ev.value)))
            isempty(evs) && continue
            vals = [ev.value for ev in evs]
            for (i, ev) in enumerate(evs)
                _onset_in(ev, s, e) && push!(out, Event{T}(ev.start, ev.stop, vals[mod1(i + n, length(vals))]))
            end
        end
        out
    end)
end
rot(n::Int) = p -> rot(n, _as_pattern(p))

"""
    hurry(n, p) — fast(n) ET speed × n (les samples montent d'autant).
"""
hurry(n::Real, p::Pattern) = fast(n, p) |> speed(n)
hurry(n::Real) = p -> hurry(n, _as_pattern(p))
hurry(np::Pattern, p::Pattern) = _per_cycle_factor(hurry, np, p)
hurry(np::Pattern) = p -> hurry(np, _as_pattern(p))
hurry(np::AbstractString) = p -> hurry(parse_minino(String(np)), _as_pattern(p))

# Le morceau `src` (0-based, sur n) du cycle `cyc` de p, joué au morceau `dst`.
function _slice_moved(p::Pattern{T}, cyc::Int, src::Int, dst::Int, n::Int, out::Vector{Event{T}}, s, e) where {T}
    a = Rational{Int64}(cyc) + Rational{Int64}(src, n)
    b = a + Rational{Int64}(1, n)
    shift = Rational{Int64}(dst - src, n)
    for ev in p(a, b)
        ev.start >= a || continue
        ns = ev.start + shift; ne = min(ev.stop, b) + shift
        _onset_in((start = ns,), s, e) && push!(out, Event{T}(ns, ne, ev.value))
    end
end
_onset_in(ev::NamedTuple, s, e) = ev.start >= s && ev.start < e

"""
    shuffle(n, p) — découpe chaque cycle en n morceaux joués dans un ordre
    aléatoire (déterministe par cycle), chacun une fois.
    scramble(n, p) — idem mais chaque position tire un morceau au hasard
    (avec répétitions possibles).
"""
function shuffle(n::Int, p::Pattern{T}) where {T}
    n > 0 || throw(ArgumentError("shuffle needs n > 0"))
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for cyc in _cycles(s, e)
            perm = sortperm([_u01((cyc, i, :shuffle)) for i in 1:n])
            for (dst, src) in enumerate(perm)
                _slice_moved(p, cyc, src - 1, dst - 1, n, out, s, e)
            end
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end
shuffle(n::Int) = p -> shuffle(n, _as_pattern(p))

function scramble(n::Int, p::Pattern{T}) where {T}
    n > 0 || throw(ArgumentError("scramble needs n > 0"))
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for cyc in _cycles(s, e), dst in 0:(n - 1)
            src = _pick(n, (cyc, dst, :scramble)) - 1
            _slice_moved(p, cyc, src, dst, n, out, s, e)
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end
scramble(n::Int) = p -> scramble(n, _as_pattern(p))

"""
    linger(f, p) — répète la première fraction `f` de chaque cycle pour le
    remplir : `linger(1//4)` boucle le premier quart.
"""
function linger(f::Real, p::Pattern{T}) where {T}
    fr = _to_rat(f)
    (0 < fr <= 1) || throw(ArgumentError("linger needs 0 < f ≤ 1"))
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for cyc in _cycles(s, e)
            a = Rational{Int64}(cyc)
            head = [ev for ev in p(a, a + fr) if ev.start >= a && ev.start < a + fr]
            k = 0
            while k * fr < 1
                shift = k * fr
                for ev in head
                    ns = ev.start + shift
                    ns < a + 1 || continue
                    (ns >= s && ns < e) && push!(out, Event{T}(ns, min(ev.stop + shift, a + 1), ev.value))
                end
                k += 1
            end
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end
linger(f::Real) = p -> linger(f, _as_pattern(p))

"""
    swingBy(x, n, p) — swing : dans chacun des n créneaux du cycle, ce qui
    tombe dans la seconde moitié est retardé de `x` créneau.
    swing(n, p) = swingBy(1//3, n, p).
"""
function swingBy(x::Real, n::Int, p::Pattern{T}) where {T}
    xr = _to_rat(x); nr = Rational{Int64}(n)
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for ev in p(s - 1//1, e)           # un peu avant : un événement décalé peut entrer dans la fenêtre
            slot = floor(Int, ev.start * nr) // nr
            pos = (ev.start - slot) * nr
            shift = pos >= 1//2 ? xr / nr : 0//1
            ns = ev.start + shift
            (ns >= s && ns < e) && push!(out, Event{T}(ns, ev.stop + shift, ev.value))
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end
swingBy(x::Real, n::Int) = p -> swingBy(x, n, _as_pattern(p))
swing(n::Int, p::Pattern) = swingBy(1//3, n, p)
swing(n::Int) = p -> swing(n, _as_pattern(p))

"""
    whenmod(a, b, f, p) — applique `f` aux cycles dont le numéro modulo `a`
    est ≥ `b` : `whenmod(8, 6, rev)` inverse les cycles 6 et 7 sur 8.
"""
whenmod(a::Int, b::Int, f, p::Pattern) = _when_cycle(cyc -> mod(cyc, a) >= b, f, p)
whenmod(a::Int, b::Int, f) = p -> whenmod(a, b, f, _as_pattern(p))

"""
    someCyclesBy(prob, f, p) / someCycles(f, p) — `f` sur certains cycles
    entiers (tirage déterministe par cycle). Alias Tidal de sometimesBy ici.
"""
someCyclesBy(prob::Real, f, p::Pattern; seed::Integer = 0) = sometimesBy(prob, f, p; seed)
someCyclesBy(prob::Real, f; seed::Integer = 0) = p -> someCyclesBy(prob, f, _as_pattern(p); seed)
someCycles(f, p::Pattern; seed::Integer = 0) = someCyclesBy(0.5, f, p; seed)
someCycles(f; seed::Integer = 0) = p -> someCycles(f, _as_pattern(p); seed)

"""
    compress(b, e, p) — tasse chaque cycle de `p` dans l'intervalle [b, e)
    du cycle (silence ailleurs). fastGap(n, p) = compress(0, 1/n, p).
"""
function compress(b::Real, e_::Real, p::Pattern{T}) where {T}
    br = _to_rat(b); er = _to_rat(e_)
    (0 <= br < er <= 1) || throw(ArgumentError("compress needs 0 ≤ b < e ≤ 1"))
    w = er - br
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for cyc in _cycles(s, e)
            a = Rational{Int64}(cyc)
            for ev in p(a, a + 1)
                ev.start >= a || continue
                ns = a + br + (ev.start - a) * w
                ne = a + br + (min(ev.stop, a + 1) - a) * w
                (ns >= s && ns < e) && push!(out, Event{T}(ns, ne, ev.value))
            end
        end
        out
    end)
end
compress(b::Real, e_::Real) = p -> compress(b, e_, _as_pattern(p))
fastGap(n::Real, p::Pattern) = compress(0, 1 // _to_rat(n), p)
fastGap(n::Real) = p -> fastGap(n, _as_pattern(p))

"""
    zoom(b, e, p) — ne joue que la portion [b, e) de chaque cycle, étirée
    sur tout le cycle : `zoom(0, 1//2)` = la première moitié, en double.
"""
function zoom(b::Real, e_::Real, p::Pattern{T}) where {T}
    br = _to_rat(b); er = _to_rat(e_)
    (0 <= br < er <= 1) || throw(ArgumentError("zoom needs 0 ≤ b < e ≤ 1"))
    w = er - br
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for cyc in _cycles(s, e)
            a = Rational{Int64}(cyc)
            for ev in p(a + br, a + er)
                ev.start >= a + br || continue
                ns = a + (ev.start - a - br) / w
                ne = a + (min(ev.stop, a + er) - a - br) / w
                (ns >= s && ns < e) && push!(out, Event{T}(ns, ne, ev.value))
            end
        end
        out
    end)
end
zoom(b::Real, e_::Real) = p -> zoom(b, e_, _as_pattern(p))

# Structure booléenne → valeurs de p échantillonnées à chaque coup.
function _struct_from_bools(bools::AbstractVector{Bool}, p::Pattern{T}) where {T}
    n = length(bools)
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for cyc in _cycles(s, e), i in 0:(n - 1)
            bools[i + 1] || continue
            a = Rational{Int64}(cyc) + Rational{Int64}(i, n)
            (a >= s && a < e) || continue
            v = _value_at(p, a)
            v === nothing || push!(out, Event{T}(a, a + Rational{Int64}(1, n), v))
        end
        out
    end)
end

"""
    euclid(k, n, p) — rythme euclidien : k coups sur n pas, valeurs prises
    dans `p`. euclidInv joue les pas vides, euclidOff(k, n, r, p) tourne de r.
"""
euclid(k::Int, n::Int, p::Pattern) = _struct_from_bools(_euclidean_pulses(k, n), p)
euclid(k::Int, n::Int) = p -> euclid(k, n, _as_pattern(p))
euclidInv(k::Int, n::Int, p::Pattern) = _struct_from_bools(.!(_euclidean_pulses(k, n)), p)
euclidInv(k::Int, n::Int) = p -> euclidInv(k, n, _as_pattern(p))
function euclidOff(k::Int, n::Int, r::Int, p::Pattern)
    b = _euclidean_pulses(k, n)
    _struct_from_bools(circshift(collect(b), -r), p)
end
euclidOff(k::Int, n::Int, r::Int) = p -> euclidOff(k, n, r, _as_pattern(p))

"""
    superimpose(f, p) — p plus f(p) par-dessus : `superimpose(fast(2))`.
    layer([f, g], p) — empile f(p), g(p), … (sans p lui-même).
"""
superimpose(f, p::Pattern) = _stack(_same_patterns((p, f(p))))
superimpose(f) = p -> superimpose(f, _as_pattern(p))
layer(fs, p::Pattern) = _stack(_same_patterns([f(p) for f in fs]))
layer(fs) = p -> layer(fs, _as_pattern(p))

"""
    inside(n, f, p) — applique f « à l'intérieur » d'un cycle découpé en n :
    `inside(2, rev)` inverse chaque moitié séparément. outside = l'inverse.
"""
inside(n::Real, f, p::Pattern) = fast(n, f(slow(n, p)))
inside(n::Real, f) = p -> inside(n, f, _as_pattern(p))
outside(n::Real, f, p::Pattern) = inside(1 // _to_rat(n), f, p)
outside(n::Real, f) = p -> outside(n, f, _as_pattern(p))

"""
    rolledBy(t, p) / rolled(p) — « roule » les accords : la i-ème note (par
    hauteur) part plus tard, de i/k × t × durée. rolled = rolledBy(1//4).
"""
function rolledBy(t::Real, p::Pattern{T}) where {T}
    tr = _to_rat(t)
    Pattern{T}((s::Rational, e::Rational) -> begin
        evs = p(s, e)
        groups = Dict{Tuple{Rational{Int64},Rational{Int64}},Vector{Event{T}}}()
        order = Tuple{Rational{Int64},Rational{Int64}}[]
        for ev in evs
            k = (ev.start, ev.stop)
            haskey(groups, k) || (groups[k] = Event{T}[]; push!(order, k))
            push!(groups[k], ev)
        end
        out = Event{T}[]
        for k in order
            notes = sort(groups[k]; by = ev -> _arp_key(ev.value))
            n = length(notes); dur = k[2] - k[1]
            for (i, ev) in enumerate(notes)
                push!(out, Event{T}(ev.start + dur * tr * (i - 1) // n, ev.stop, ev.value))
            end
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end
rolledBy(t::Real) = p -> rolledBy(t, _as_pattern(p))
rolled(p::Pattern) = rolledBy(1//4, p)
rolled(p) = rolled(_as_pattern(p))

"""
    brak(p) — un cycle sur deux, le pattern est tassé dans la première
    moitié et décalé d'un quart : le « break » de Tidal.
"""
function brak(p::Pattern{T}) where {T}
    alt = late(1//4, compress(0, 1//2, p))
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for cyc in _cycles(s, e)
            q = isodd(cyc) ? alt : p
            lo = max(Rational{Int64}(cyc), s); hi = min(Rational{Int64}(cyc + 1), e)
            lo < hi && append!(out, q(lo, hi))
        end
        out
    end)
end
brak(p) = brak(_as_pattern(p))

"""
    stut(n, feedback, time, p) — écho : n copies, chacune `time` cycle plus
    tard et gain × feedback à chaque fois.
"""
function stut(n::Int, feedback::Real, time::Real, p)
    n >= 1 || throw(ArgumentError("stut needs n ≥ 1"))
    base = _lift_to_control(_as_pattern(p))
    layers = [i == 0 ? base : (late(time * i, base) |> gain(feedback^i)) for i in 0:(n - 1)]
    return _stack(layers)
end
stut(n::Int, feedback::Real, time::Real) = p -> stut(n, feedback, time, p)


# ── Les visuels demandés dans le pattern ─────────────────────────────
# Comme dans Strudel : on demande son visuel là où on écrit le pattern.
# Ces fonctions ne changent rien à ce qui joue ; l'interface lit leur nom
# dans le texte du slot et dessine (pixel_layer.jl).

"""
    pianoroll()
    pattern |> pianoroll()

Shows this slot's piano roll in the editor (pixel grid). Leaves the pattern unchanged.
"""
pianoroll(p) = _as_pattern(p)
pianoroll() = p -> pianoroll(p)

"""
    pitchwheel()
    pattern |> pitchwheel()

Shows this slot's pitch wheel in the editor (pixel grid). Leaves the pattern unchanged.
"""
pitchwheel(p) = _as_pattern(p)
pitchwheel() = p -> pitchwheel(p)
