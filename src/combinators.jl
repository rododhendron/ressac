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
fast(n::Real) = x -> fast(n, x isa Symbol ? pure(x) : x)

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
slow(n::Real) = x -> slow(n, x isa Symbol ? pure(x) : x)

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
every(n::Int, f) = x -> every(n, f, x isa Symbol ? pure(x) : x)

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
    p_pat = p isa Symbol ? pure(p) : p
    return stack(p_pat |> pan(0.0), f(p_pat) |> pan(1.0))
end
jux(f) = p -> jux(f, p)

"""
    juxBy(amount, f, p) -> Pattern

`jux` with reduced stereo spread. `amount=1` is full L/R, `amount=0`
collapses both copies to center.
"""
function juxBy(amount::Real, f, p)
    p_pat = p isa Symbol ? pure(p) : p
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
function off(t::Real, f, p::Pattern{T}) where {T}
    t_rat = _to_rat(t)
    shifted = Pattern{T}((s::Rational, e::Rational) -> begin
        inner = f(p)(s - t_rat, e - t_rat)
        [Event{T}(ev.start + t_rat, ev.stop + t_rat, ev.value) for ev in inner]
    end)
    return stack(p, shifted)
end
off(t::Real, f) = p -> off(t, f, p isa Symbol ? pure(p) : p)

"""
    degradeBy(prob, p) -> Pattern{T}

Drop each event from `p` with probability `prob` (0..1). Seeded by
`hash(ev.start)` so successive renders produce the same drops — the
groove is repeatable.
"""
function degradeBy(prob::Real, p::Pattern{T}) where {T}
    pr = clamp(float(prob), 0.0, 1.0)
    Pattern{T}((s::Rational, e::Rational) -> begin
        [ev for ev in p(s, e) if
         (hash(ev.start) % UInt32(1_000_000)) / 1_000_000.0 >= pr]
    end)
end
degradeBy(prob::Real) = p -> degradeBy(prob, p isa Symbol ? pure(p) : p)

"""
    degrade(p) -> Pattern{T}

Shortcut for `degradeBy(0.5, p)`. Drops half the events at random.
"""
degrade(p) = degradeBy(0.5, p isa Symbol ? pure(p) : p)

"""
    sometimesBy(prob, f, p) -> Pattern{T}

Apply transform `f` to `p` with probability `prob` per cycle. The
decision is per cycle (not per event) so a "sometimes faster" treats
the whole cycle uniformly.
"""
function sometimesBy(prob::Real, f, p::Pattern{T}) where {T}
    pr = clamp(float(prob), 0.0, 1.0)
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        n_start = floor(Int, s)
        n_stop  = ceil(Int, e)
        for cyc in n_start:(n_stop - 1)
            a = max(Rational{Int64}(cyc), s)
            b = min(Rational{Int64}(cyc + 1), e)
            a < b || continue
            r = (hash(cyc) % UInt32(1_000_000)) / 1_000_000.0
            chosen = r < pr ? f(p) : p
            for ev in chosen(a, b)
                push!(out, ev)
            end
        end
        out
    end)
end
sometimesBy(prob::Real, f) = p -> sometimesBy(prob, f, p isa Symbol ? pure(p) : p)

"""
    sometimes(f, p) — `sometimesBy(0.5, …)`
    often(f, p)     — `sometimesBy(0.75, …)`
    rarely(f, p)    — `sometimesBy(0.25, …)`
"""
sometimes(f, p) = sometimesBy(0.5, f, p isa Symbol ? pure(p) : p)
sometimes(f)    = p -> sometimes(f, p)
often(f, p)     = sometimesBy(0.75, f, p isa Symbol ? pure(p) : p)
often(f)        = p -> often(f, p)
rarely(f, p)    = sometimesBy(0.25, f, p isa Symbol ? pure(p) : p)
rarely(f)       = p -> rarely(f, p)

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
iter(n::Int) = p -> iter(n, p isa Symbol ? pure(p) : p)

"""
    chunk(n, f, p) -> Pattern{T}

Split each cycle into `n` equal chunks; apply `f` to a different
chunk per cycle, leaving the others as-is. Cycles through chunks
0..n-1 then repeats.
"""
function chunk(n::Int, f, p::Pattern{T}) where {T}
    n >= 1 || throw(ArgumentError("chunk count must be ≥ 1"))
    Pattern{T}((s::Rational, e::Rational) -> begin
        out = Event{T}[]
        n_start = floor(Int, s)
        n_stop  = ceil(Int, e)
        chunk_dur = Rational{Int64}(1, n)
        for cyc in n_start:(n_stop - 1)
            base = Rational{Int64}(cyc)
            a = max(base, s)
            b = min(base + 1, e)
            a < b || continue
            active = cyc % n  # which chunk gets the transform this cycle
            for k in 0:(n - 1)
                seg_start = base + k * chunk_dur
                seg_stop  = base + (k + 1) * chunk_dur
                seg_a = max(seg_start, a)
                seg_b = min(seg_stop,  b)
                seg_a < seg_b || continue
                pp = (k == active) ? f(p) : p
                for ev in pp(seg_a, seg_b)
                    push!(out, ev)
                end
            end
        end
        out
    end)
end
chunk(n::Int, f) = p -> chunk(n, f, p isa Symbol ? pure(p) : p)
