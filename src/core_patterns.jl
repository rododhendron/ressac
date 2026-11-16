"""
    _to_rat(x)

Coerce a real number to `Rational{Int64}`. Integers and rationals convert
exactly; floats are rationalized via a continued fraction with the default
tolerance, which handles common musical values (1/2, 1/3, 1/4, ...) precisely.
"""
_to_rat(x::Rational) = Rational{Int64}(x)
_to_rat(x::Integer) = Rational{Int64}(x)
_to_rat(x::AbstractFloat) = rationalize(Int64, x)

"""
    Event{T}(start, stop, value)

A timed event: a value of type `T` placed in the half-open arc `[start, stop)`.
Times are `Rational{Int64}` (in cycles), giving exact arithmetic over arbitrarily
long sessions.

`Event{T}` is an immutable bitstype-ish struct, so `==` and `hash` are correct
out of the box (field-wise comparison via `===`).
"""
struct Event{T}
    start::Rational{Int64}
    stop::Rational{Int64}
    value::T
end

"""
    Pattern{T}(query)
    Pattern{T}(query, held)

Un pattern est d'abord une requête `(s, e) -> Vector{Event{T}}`.

Contrat de `query` — la requête **d'attaque** :
- elle rend les événements qui **commencent** dans `[s, e)`, chacun avec son
  créneau entier (jamais rogné à la fenêtre : un événement de deux cycles
  est rendu une fois, dans la fenêtre de son attaque, avec `stop - start == 2`) ;
- triés par `start` croissant ;
- déterministe par fenêtre.

C'est ce que demande la lecture : le scheduler interroge cycle par cycle et
joue chaque attaque une fois, sans jamais prendre un fragment pour un coup.

Mais « quelle valeur est en cours à l'instant t ? » est une autre question —
celle d'un contrôle (`lpf("<400 2000>/2")`), d'un masque, d'un facteur
patterné. Un événement commencé avant la fenêtre peut être encore tenu.
C'est la requête **de tenue**, [`_held`](@ref) : tous les événements dont le
créneau recouvre `[s, e)`.

`held` est la tenue exacte quand le pattern sait la donner (`pure`, la
mini-notation, `fast`/`slow`, `early`/`late`, `stack`, les signaux continus…).
Sinon (`nothing`), `_held` la reconstruit depuis `query` en regardant
`_HELD_LOOKBACK` cycles en arrière.

Les signaux continus (`sine()`, `rand_pat()`…) répondent à toute fenêtre par
un seul événement échantillonné : leur tenue est leur requête.
"""
struct Pattern{T}
    query::Function
    held::Union{Nothing,Function}
end
Pattern{T}(query::Function) where {T} = Pattern{T}(query, nothing)

# Jusqu'où `_held` remonte quand un pattern ne sait pas donner sa tenue : un
# événement plus long que ça, passé par un combinateur qui ne la transmet
# pas, n'est plus vu après ce délai. Les sources et les transformations de
# temps la donnent exactement, sans cette borne.
const _HELD_LOOKBACK = 16

"""
    _held(p, s, e) -> Vector{Event{T}}

Les événements de `p` dont le créneau recouvre `[s, e)`, créneaux entiers,
triés par `start`. Voir [`Pattern`](@ref).
"""
function _held(p::Pattern{T}, s::Rational, e::Rational) where {T}
    p.held === nothing || return p.held(s, e)::Vector{Event{T}}
    # Ce qui a commencé avant la fenêtre et dure encore, puis ce qui y
    # commence. Deux requêtes distinctes : un signal continu, s'il est
    # caché derrière un combinateur, répond à la première par un événement
    # qui s'arrête à `s` (écarté) et à la seconde par son échantillon.
    out = Event{T}[ev for ev in p(s - _HELD_LOOKBACK, s) if ev.stop > s]
    append!(out, p(s, e))
    return out
end

# Fenêtre minuscule pour lire « à l'instant t » : assez courte pour qu'un
# signal continu y soit échantillonné à t, assez grossière pour ne pas faire
# déborder les rationnels en aval.
const _INSTANT = 1 // 4096

"""
    _event_at(p, t) -> Union{Event{T}, Nothing}

L'événement de `p` en cours à l'instant `t` (`start <= t < stop`) — le
dernier commencé s'il y en a plusieurs.
"""
function _event_at(p::Pattern{T}, t::Rational) where {T}
    found = nothing
    for ev in _held(p, t, t + _INSTANT)
        ev.start <= t < ev.stop || continue
        (found === nothing || ev.start >= found.start) && (found = ev)
    end
    return found
end

# Callable shorthand: `p(0//1, 1//1)` ≡ `p.query(0//1, 1//1)`.
(p::Pattern)(s::Rational, e::Rational) = p.query(s, e)
(p::Pattern)(s::Real, e::Real) = p.query(_to_rat(s), _to_rat(e))

"""
    query(p, s, e)

Functional alias for `p(s, e)`. Accepts any `Real` for `s`/`e`; non-rational
inputs are coerced via [`_to_rat`](@ref).
"""
query(p::Pattern, s::Rational, e::Rational) = p(s, e)
query(p::Pattern, s::Real, e::Real) = p(_to_rat(s), _to_rat(e))

# ── Hasard déterministe ──────────────────────────────────────────────
# Tout tirage du moteur est une fonction de sa clé (un instant, un cycle, un
# rang) : deux rendus du même cycle donnent le même son. Une seule source,
# `_u01` — `hash` de Julia suivi du mélangeur de splitmix64, parce que les
# bits bas de `hash` (et son second argument) sont trop peu mélangés pour
# être réduits tels quels par un modulo.
function _mix64(h::UInt64)
    h ⊻= h >> 30; h *= 0xbf58476d1ce4e5b9
    h ⊻= h >> 27; h *= 0x94d049bb133111eb
    return h ⊻ (h >> 31)
end

"""
    _u01(key) -> Float64 dans [0, 1)
    _u01(key, salt)

Tirage uniforme déterministe. `salt` décorrèle deux usages de la même clé.
"""
_u01(key) = (_mix64(UInt64(hash(key))) >> 11) * (1.0 / (UInt64(1) << 53))
_u01(key, salt::Integer) = _u01((key, salt))

# Indice tiré dans 1:n.
_pick(n::Integer, key) = min(n, floor(Int, _u01(key) * n) + 1)
