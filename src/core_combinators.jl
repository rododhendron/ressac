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
fast(n::Real) = x -> fast(n, _as_pattern(x))

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
every(n::Int, f) = x -> every(n, f, _as_pattern(x))

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
function off(t::Real, f, p::Pattern{T}) where {T}
    t_rat = _to_rat(t)
    shifted = Pattern{T}((s::Rational, e::Rational) -> begin
        inner = f(p)(s - t_rat, e - t_rat)
        [Event{T}(ev.start + t_rat, ev.stop + t_rat, ev.value) for ev in inner]
    end)
    return stack(p, shifted)
end
off(t::Real, f) = p -> off(t, f, _as_pattern(p))

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
degradeBy(prob::Real) = p -> degradeBy(prob, _as_pattern(p))

"""
    degrade(p) -> Pattern{T}

Shortcut for `degradeBy(0.5, p)`. Drops half the events at random.
"""
degrade(p) = degradeBy(0.5, _as_pattern(p))

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
sometimesBy(prob::Real, f) = p -> sometimesBy(prob, f, _as_pattern(p))

"""
    sometimes(f, p) — `sometimesBy(0.5, …)`
    often(f, p)     — `sometimesBy(0.75, …)`
    rarely(f, p)    — `sometimesBy(0.25, …)`
"""
sometimes(f, p) = sometimesBy(0.5, f, _as_pattern(p))
sometimes(f)    = p -> sometimes(f, p)
often(f, p)     = sometimesBy(0.75, f, _as_pattern(p))
often(f)        = p -> often(f, p)
rarely(f, p)    = sometimesBy(0.25, f, _as_pattern(p))
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
iter(n::Int) = p -> iter(n, _as_pattern(p))

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
function lastOf(n::Int, f, p::Pattern{T}) where {T}
    n > 0 || throw(ArgumentError("lastOf needs n > 0"))
    transformed = f(p)::Pattern{T}
    Pattern{T}((s::Rational, e::Rational) -> begin
        n_start = floor(Int, s)
        n_stop  = ceil(Int, e)
        out = Event{T}[]
        for cyc in n_start:(n_stop - 1)
            a = max(Rational{Int64}(cyc), s)
            b = min(Rational{Int64}(cyc + 1), e)
            a < b || continue
            chosen = (mod(cyc + 1, n) == 0) ? transformed : p
            append!(out, chosen(a, b))
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
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
    Pattern{T}((s::Rational, e::Rational) -> begin
        inner = p(s + dt, e + dt)
        [Event{T}(ev.start - dt, ev.stop - dt, ev.value) for ev in inner]
    end)
end
early(t::Real) = p -> early(t, _as_pattern(p))

"""
    late(t, p) -> Pattern{T}

Shift `p` `t` cycles LATER. Equivalent to `early(-t, p)`.
"""
late(t::Real, p) = early(-_to_rat(t), _as_pattern(p))
late(t::Real)    = p -> late(t, _as_pattern(p))

"""
    ply(n, p) -> Pattern{T}

Repeat each event `n` times within its own slot (Tidal's `ply`).
`ply(3, p"bd sn")` plays `bd bd bd sn sn sn` over one cycle.
"""
function ply(n::Int, p::Pattern{T}) where {T}
    n > 0 || throw(ArgumentError("ply needs n > 0"))
    Pattern{T}((s::Rational, e::Rational) -> begin
        inner = p(s, e)
        out = Event{T}[]
        n_rat = Rational{Int64}(n)
        for ev in inner
            width = ev.stop - ev.start
            slice = width / n_rat
            for i in 0:(n - 1)
                a = ev.start + slice * i
                b = i == n - 1 ? ev.stop : ev.start + slice * (i + 1)
                a < e && b > s &&
                    push!(out, Event{T}(max(a, s), min(b, e), ev.value))
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

One random pick from `xs` per cycle. Same seed → same pick (the
choice is `hash(cycle) mod length(xs)`), so the result is
deterministic for a given session start.
"""
function choose(xs::AbstractVector{T}) where {T}
    n = length(xs)
    n > 0 || throw(ArgumentError("choose needs at least one element"))
    Pattern{T}((s::Rational, e::Rational) -> begin
        n_start = floor(Int, s)
        n_stop  = ceil(Int, e)
        out = Event{T}[]
        for cyc in n_start:(n_stop - 1)
            idx = mod(hash(cyc) % UInt32, UInt32(n)) + 1
            a = max(Rational{Int64}(cyc), s)
            b = min(Rational{Int64}(cyc + 1), e)
            a < b && push!(out, Event{T}(a, b, xs[idx]))
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

Continuous waveform patterns, one cycle = one period. Output range
`[-1, 1]` for sine/cosine/tri, `[0, 1]` for saw, `{0, 1}` for square.
Used with `range(min, max)` and `segment(n)` to modulate other patterns.
"""
sine()   = _continuous(t -> sin(2π * t))
cosine() = _continuous(t -> cos(2π * t))
tri()    = _continuous(t -> begin u = mod(t, 1.0); u < 0.5 ? (4u - 1) : (3 - 4u) end)
saw()    = _continuous(t -> mod(t, 1.0))
square() = _continuous(t -> mod(t, 1.0) < 0.5 ? 0.0 : 1.0)

"""
    rand() -> Pattern{Float64}

Continuous-ish random pattern: deterministic per cycle index but
varying across cycles (so it doesn't freeze on a single value).
Output `[0, 1)`. For discrete sampling use `rand() |> segment(n)`.
"""
function rand_pat()
    Pattern{Float64}((s::Rational, e::Rational) -> begin
        cyc = floor(Int, s)
        mid = (s + e) / 2
        v = (hash(cyc, hash(Float64(mid))) % UInt32) / Float64(typemax(UInt32))
        [Event{Float64}(s, e, v)]
    end)
end

"""
    perlin() -> Pattern{Float64}

Smoothed-random pattern (cheap 1D value-noise — not true Perlin
but the use-case is identical: slowly-changing random in [0, 1)).
Adjacent cycles' values are interpolated via cosine smoothstep.
"""
function perlin()
    _h(c) = (hash(c, UInt(0x517cc1b727220a95)) % UInt32) / Float64(typemax(UInt32))
    Pattern{Float64}((s::Rational, e::Rational) -> begin
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
function _continuous(f)
    Pattern{Float64}((s::Rational, e::Rational) -> begin
        mid = Float64((s + e) / 2)
        [Event{Float64}(s, e, f(mid))]
    end)
end

"""
    range(lo, hi, p) -> Pattern{Float64}
    range(lo, hi)    -> (Pattern -> Pattern)

Linearly remap `p`'s output from `[-1, 1]` (or `[0, 1]` — whichever
is its natural range) into `[lo, hi]`. The detection is naive:
values in `[-1, 0)` are rescaled assuming a bipolar source; values
in `[0, 1]` from a unipolar source pass through `[lo, hi]` directly.

In practice, `sine() |> range(400, 4000)` does what you'd expect.
"""
function range_pat(lo::Real, hi::Real, p::Pattern{Float64})
    lo_f = Float64(lo); hi_f = Float64(hi)
    Pattern{Float64}((s::Rational, e::Rational) -> begin
        inner = p(s, e)
        [Event{Float64}(ev.start, ev.stop,
                        lo_f + (hi_f - lo_f) * ((ev.value + 1) / 2))
         for ev in inner]
    end)
end
range_pat(lo::Real, hi::Real) = p -> range_pat(lo, hi, _as_pattern(p))

"""
    segment(n, p) -> Pattern{Float64}
    segment(n)    -> (Pattern -> Pattern)

Sample a continuous pattern `n` times per cycle, producing `n`
discrete events with the value of `p` at each segment's midpoint.
Converts a continuous signal into a usable event stream.
"""
function segment(n::Int, p::Pattern{Float64})
    n > 0 || throw(ArgumentError("segment needs n > 0"))
    Pattern{Float64}((s::Rational, e::Rational) -> begin
        n_start = floor(Int, s)
        n_stop  = ceil(Int, e)
        out = Event{Float64}[]
        n_rat = Rational{Int64}(n)
        for cyc in n_start:(n_stop - 1)
            for i in 0:(n - 1)
                a = Rational{Int64}(cyc) + Rational{Int64}(i) / n_rat
                b = Rational{Int64}(cyc) + Rational{Int64}(i + 1) / n_rat
                a < e && b > s || continue
                evs = p(a, b)
                isempty(evs) && continue
                ca = max(a, s); cb = min(b, e)
                push!(out, Event{Float64}(ca, cb, evs[1].value))
            end
        end
        out
    end)
end
segment(n::Int) = p -> segment(n, p)

# ---------------------------------------------------------------------------
# Sample slicing — striate / chop
# ---------------------------------------------------------------------------
#
# Both produce N events per cycle from a single sample symbol, each event
# carrying SuperDirt's `:begin`/`:end` params so SC plays only the slice
# `[i/N, (i+1)/N)` of the sample's audio. Difference:
#
#   striate(N, p)  — N slices, INTERLEAVED across cycles. Each cycle gets
#                    N events in the cycle's natural order: slice 0 ..
#                    slice N-1. The sample is sliced uniformly.
#   chop(N, p)     — same N events per cycle, same begin/end positions.
#                    Functionally identical to striate for our purposes
#                    (Tidal's chop has different semantics for compound
#                    events; we expose them as aliases until that lands).
#
# Routing: events carry a ControlMap with `:s` (sample), `:begin`, `:end`,
# `:n` (variant, default 0). Pipe-friendly: `:bd |> striate(8)`.

"""
    striate(n, p) -> Pattern{ControlMap}
    striate(n)    -> (Pattern{Symbol} -> Pattern{ControlMap})

Slice each sample event of `p` into `n` equal-time segments, emitting
`n` ControlMap events per cycle with `:begin = i/n` and `:end = (i+1)/n`
so SuperDirt plays only the matching slice of audio. Useful for
amen-break choppage, granular textures, lo-fi sample mangling.

```julia
@d1 :amen |> striate(8)        # 8 even chops per cycle
@d1 :amen |> striate(16) |> rev   # backward chops
```
"""
function striate(n::Int, p::Pattern{Symbol})
    n > 0 || throw(ArgumentError("striate needs n > 0"))
    Pattern{ControlMap}((s::Rational, e::Rational) -> begin
        inner = p(s, e)
        out = Event{ControlMap}[]
        n_rat = Rational{Int64}(n)
        for ev in inner
            width = ev.stop - ev.start
            slice = width / n_rat
            for i in 0:(n - 1)
                a = ev.start + slice * i
                b = i == n - 1 ? ev.stop : ev.start + slice * (i + 1)
                a < e && b > s || continue
                cm = ControlMap(:s => ev.value,
                                :begin => Float32(i) / Float32(n),
                                :end   => Float32(i + 1) / Float32(n))
                push!(out, Event{ControlMap}(max(a, s), min(b, e), cm))
            end
        end
        sort!(out, by = ev -> ev.start)
        out
    end)
end
striate(n::Int) = p -> striate(n, _as_pattern(p))

"""
    chop(n, p) -> Pattern{ControlMap}
    chop(n)    -> (Pattern{Symbol} -> Pattern{ControlMap})

Alias of [`striate`](@ref) for now. Tidal differentiates `chop`
from `striate` via compound-event semantics that we haven't
implemented yet (Tidal's `chop` preserves the original event arc
and emits N sub-events INSIDE it, whereas `striate` interleaves
slices across cycles). Until then both ship the same OSC payload.
"""
chop(n::Int, p::Pattern{Symbol}) = striate(n, p)
chop(n::Int) = p -> chop(n, _as_pattern(p))

"""
    chopp(n) -> (Pattern{Symbol} -> Pattern{ControlMap})

Exported alias of [`chop`](@ref). Renamed to avoid clashing with
`Base.chop` (which trims trailing characters from a string).
"""
const chopp = chop
