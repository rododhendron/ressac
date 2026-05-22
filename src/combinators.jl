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
        n_stop = ceil(Int, e)
        for n in n_start:(n_stop - 1)
            a = max(Rational{Int64}(n), s)
            b = min(Rational{Int64}(n + 1), e)
            a < b && push!(events, Event{T}(a, b, v))
        end
        events
    end)
end

"""
    silence(T) -> Pattern{T}

The empty pattern for value type `T`. Useful as a placeholder when wiring
slots and for algebraic identities (`stack(p, silence(T)) ≡ p`).
"""
silence(::Type{T}) where {T} =
    Pattern{T}((_s::Rational, _e::Rational) -> Event{T}[])

"""
    fast(n, p) -> Pattern{T}

Compress time by factor `n`: events that occupied one cycle in `p` now occupy
`1/n` cycle. `fast(2, p)` plays `p` at twice the speed.

Throws `ArgumentError` if `n == 0`.
"""
function fast(n::Real, p::Pattern{T}) where {T}
    n_rat = _to_rat(n)
    iszero(n_rat) && throw(ArgumentError("fast factor cannot be zero"))
    Pattern{T}((s::Rational, e::Rational) -> begin
        inner = p(s * n_rat, e * n_rat)
        [Event{T}(ev.start / n_rat, ev.stop / n_rat, ev.value) for ev in inner]
    end)
end

"""
    fast(n::Real) -> (Pattern -> Pattern)

Curried form: `fast(n)(p) == fast(n, p)`. Lets `p |> fast(n)` thread the
pattern as the right-hand arg under Julia's native `|>`.
"""
fast(n::Real) = p::Pattern -> fast(n, p)

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
slow(n::Real) = p::Pattern -> slow(n, p)

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
        n_start = floor(Int, s)
        n_stop = ceil(Int, e)
        inner = p(Rational{Int64}(n_start), Rational{Int64}(n_stop))
        out = Event{T}[]
        for ev in inner
            n = floor(Int, ev.start)
            mirror = Rational{Int64}(2n + 1)
            new_start = mirror - ev.stop
            new_stop  = mirror - ev.start
            a = max(new_start, s)
            b = min(new_stop, e)
            a < b && push!(out, Event{T}(a, b, ev.value))
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end

"""
    every(n, f, p) -> Pattern{T}

Apply transformation `f` to `p` on every `n`-th cycle (cycles `0, n, 2n, ...`);
play `p` unchanged on the other cycles.

`f` is called **once**, at construction time, to build the transformed pattern.
"""
function every(n::Int, f, p::Pattern{T}) where {T}
    n > 0 || throw(ArgumentError("every needs n > 0"))
    transformed = f(p)::Pattern{T}
    Pattern{T}((s::Rational, e::Rational) -> begin
        n_start = floor(Int, s)
        n_stop = ceil(Int, e)
        out = Event{T}[]
        for cyc in n_start:(n_stop - 1)
            a = max(Rational{Int64}(cyc), s)
            b = min(Rational{Int64}(cyc + 1), e)
            a < b || continue
            chosen = (mod(cyc, n) == 0) ? transformed : p
            append!(out, chosen(a, b))
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end

"""
    every(n::Int, f) -> (Pattern -> Pattern)

Curried form: `every(n, f)(p) == every(n, f, p)`.
"""
every(n::Int, f) = p::Pattern -> every(n, f, p)

"""
    stack(ps::Pattern{T}...) -> Pattern{T}

Layer patterns in parallel: every event of every input pattern is emitted.
Extends `Base.stack`.
"""
function stack(ps::Pattern{T}...) where {T}
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        for p in ps
            append!(out, p(s, e))
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end

"""
    stack(q::Pattern{T}) -> (Pattern{T} -> Pattern{T})

Curried form: `stack(q)(p) == stack(p, q)`. Note: existing
`stack(ps::Vararg{Pattern{T}})` already covers `stack(p, q, r, …)`, so
this single-arg version disambiguates as "curry on the lone arg".
"""
stack(q::Pattern{T}) where {T} = p::Pattern{T} -> stack(p, q)

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
