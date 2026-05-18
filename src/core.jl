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

A pattern is a query function `(s, e) -> Vector{Event{T}}` returning the events
that overlap the half-open arc `[s, e)`.

Contract for `query`:
- Returned events are **clipped** to `[s, e)` (an event whose original arc
  overhangs the window is returned with its `start`/`stop` truncated).
- Events are sorted by `start` (ascending).
- `query` is deterministic per window. State-carrying patterns (e.g. the
  future `ReservoirPattern`) are the explicitly-documented exception.
"""
struct Pattern{T}
    query::Function
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
