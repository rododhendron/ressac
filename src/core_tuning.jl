# src/core_tuning.jl
# Microtonal scale system — single immutable Scale type, fractional
# semitones, arbitrary period (octave OR not). Every higher-level
# construct (EDO, just intonation, Bohlen-Pierce, geometric tunings,
# pattern combinators) builds on top.
#
# Design doc: docs/journal/20260601_microtonal_design.md

"""
    Scale(name, cents, period_cents)

Immutable description of a microtonal scale.

  * `name`         — symbolic identifier (used for registry lookup
                     and display)
  * `cents`        — degree offsets within ONE period, strictly
                     increasing, must start at `0.0`, all values
                     `< period_cents`
  * `period_cents` — the repeating interval in cents. `1200.0` for
                     octave-based scales (most Western + Indian +
                     Arab traditions); other values for xenharmonic
                     systems (Bohlen-Pierce uses `1901.955...` =
                     the tritave 3:1).

A `Scale` is a function from degree (integer or fractional) to
semitones, suitable for SuperDirt's `:note` control:

    julia> myscale = Scale(:n5, [0.0, 240.0, 480.0, 720.0, 960.0], 1200.0)
    julia> scale_to_semitones(myscale, 0)       # root
    0.0
    julia> scale_to_semitones(myscale, 1)
    2.4
    julia> scale_to_semitones(myscale, 5)       # one period up
    12.0
"""
struct Scale
    name::Symbol
    cents::Vector{Float64}
    period_cents::Float64

    function Scale(name::Symbol, cents::Vector{Float64}, period_cents::Real)
        isempty(cents) && throw(ArgumentError("Scale($name): cents must not be empty"))
        cents[1] == 0.0 || throw(ArgumentError("Scale($name): cents must start at 0.0"))
        period_cents > 0 || throw(ArgumentError("Scale($name): period_cents must be > 0"))
        for i in 2:length(cents)
            cents[i] > cents[i-1] ||
                throw(ArgumentError("Scale($name): cents must be strictly increasing"))
        end
        cents[end] < period_cents ||
            throw(ArgumentError("Scale($name): last cents ($(cents[end])) must be < period_cents ($period_cents)"))
        return new(name, cents, Float64(period_cents))
    end
end

# Convenience: accept any Real vector + default octave.
Scale(name::Symbol, cents::AbstractVector{<:Real}) =
    Scale(name, Float64.(collect(cents)), 1200.0)
Scale(name::Symbol, cents::AbstractVector{<:Real}, period_cents::Real) =
    Scale(name, Float64.(collect(cents)), period_cents)

Base.length(s::Scale) = length(s.cents)
Base.show(io::IO, s::Scale) = print(io,
    "Scale($(s.name), $(length(s.cents)) degrees, period=$(round(s.period_cents; digits=2))¢)")

"""
    scale_to_semitones(s::Scale, degree::Real) -> Float64

Map a scale degree to semitones (SuperDirt `:note` units).
`degree == 0` → root. Positive degrees walk up the scale, wrapping
into the next period when they exceed `length(s.cents)`. Negative
degrees walk down. Fractional degrees linearly interpolate between
adjacent scale steps — useful for glissandi and continuous pitch
patterns.

    julia> s = Scale(:major, [0,200,400,500,700,900,1100], 1200)
    julia> scale_to_semitones(s, 0)          # C
    0.0
    julia> scale_to_semitones(s, 4)          # G — 700¢ → 7 semitones
    7.0
    julia> scale_to_semitones(s, 7)          # C one octave up
    12.0
    julia> scale_to_semitones(s, -1)         # B below root
    -1.0
    julia> scale_to_semitones(s, 0.5)        # halfway between root & 2nd
    1.0
"""
function scale_to_semitones(s::Scale, degree::Real)
    cents = _scale_to_cents(s, degree)
    return cents / 100.0
end

function _scale_to_cents(s::Scale, degree::Real)
    n = length(s.cents)
    if degree isa Integer || degree == floor(degree)
        d = Int(floor(degree))
        oct, idx = divrem(d, n)
        if idx < 0
            idx += n
            oct -= 1
        end
        return s.cents[idx + 1] + oct * s.period_cents
    end
    # Fractional — interpolate linearly between two adjacent steps.
    # Floor (degree) gives the lower index; degree - floor(degree)
    # is the interpolation weight toward the next step.
    d_floor = floor(degree)
    frac = degree - d_floor
    lo = _scale_to_cents(s, Int(d_floor))
    hi = _scale_to_cents(s, Int(d_floor) + 1)
    return lo + frac * (hi - lo)
end

# ── Registry ────────────────────────────────────────────────────────

"""
    _SCALES

Global registry of named `Scale` values. Plugins contribute via the
`[[scales]]` plugin.toml section; users can also register their own
at the REPL via `register_scale!`. Lookup by symbol via
`lookup_scale(:name)`.
"""
const _SCALES = Dict{Symbol, Scale}()

"""
    register_scale!(s::Scale) -> Scale

Register `s` under its `name`. Last-wins on collision with a
warning naming both names so the user can chase a surprise
override. Returns `s` for chaining.
"""
function register_scale!(s::Scale)
    if haskey(_SCALES, s.name)
        @warn "scale ':$(s.name)' shadowed; previous definition replaced"
    end
    _SCALES[s.name] = s
    return s
end

"""
    lookup_scale(name) -> Union{Scale, Nothing}

Resolve a registered scale by symbol. Returns `nothing` if absent.
"""
lookup_scale(name::Symbol) = get(_SCALES, name, nothing)
lookup_scale(name::AbstractString) = lookup_scale(Symbol(name))

"""
    list_scales() -> Vector{Symbol}

Every registered scale name, alphabetically sorted.
"""
list_scales() = sort!(collect(keys(_SCALES)))

# ── Constructors ────────────────────────────────────────────────────

"""
    edo(name, n; period_cents = 1200.0) -> Scale

Equal divisions of a period — `n` evenly spaced steps within one
`period_cents` interval. `edo(:n12, 12)` recreates plain 12-tone
equal temperament (chromatic scale). `edo(:n19, 19)` gives 19-EDO.
Pass a non-octave period for Bohlen-Pierce style equal divisions
(e.g. `edo(:bp_eq, 13; period_cents = 1200 * log2(3))`).
"""
function edo(name::Symbol, n::Integer; period_cents::Real = 1200.0)
    n > 0 || throw(ArgumentError("edo: n must be positive"))
    cents = [period_cents * (i - 1) / n for i in 1:n]
    return Scale(name, cents, period_cents)
end

"""
    from_ratios(name, ratios) -> Scale

Build a `Scale` from frequency ratios relative to the root. The
last ratio defines the period. Examples:

    just_major = from_ratios(:just_major,
                              [1//1, 9//8, 5//4, 4//3, 3//2, 5//3, 15//8, 2//1])

Internally converts each ratio to cents via `1200 * log2(r / r₀)`,
where `r₀ = ratios[1]`. The last ratio is dropped from `cents` (it
IS the period).
"""
function from_ratios(name::Symbol, ratios::AbstractVector{<:Real})
    length(ratios) >= 2 ||
        throw(ArgumentError("from_ratios: need at least 2 ratios (root + period)"))
    r0 = Float64(ratios[1])
    r0 > 0 || throw(ArgumentError("from_ratios: ratios must be positive"))
    cents = [1200.0 * log2(Float64(r) / r0) for r in ratios[1:end-1]]
    period = 1200.0 * log2(Float64(ratios[end]) / r0)
    return Scale(name, cents, period)
end

"""
    from_cents(name, cents; period_cents = 1200.0) -> Scale

Build a `Scale` directly from a cents list. Sugar for the bare
`Scale(...)` constructor — present for symmetry with `edo` /
`from_ratios`. The list must start at 0 and be strictly increasing,
all values `< period_cents`.
"""
from_cents(name::Symbol, cents::AbstractVector{<:Real}; period_cents::Real = 1200.0) =
    Scale(name, Float64.(collect(cents)), period_cents)

"""
    bohlen_pierce(name = :bp_lambda; variant = :lambda) -> Scale

Bohlen-Pierce — equal divisions of the tritave (3:1), `13` steps,
period = `1200 * log2(3)` ≈ `1901.955¢`. Variants pick different
subsets of the 13 steps as the playable scale:

  * `:eq`     — all 13 steps (equal-tempered Bohlen-Pierce)
  * `:lambda` — 9 steps, BP "major" mode
  * `:dur`    — 9 steps, BP "major" alternative voicing
  * `:moll`   — 9 steps, BP "minor"

References: M.V. Mathews & J.R. Pierce 1984, the BP site
(bohlen-pierce-conference.org).
"""
function bohlen_pierce(name::Symbol = :bp_lambda; variant::Symbol = :lambda)
    n = 13
    period = 1200.0 * log2(3.0)
    all_steps = [period * i / n for i in 0:(n-1)]
    picks = if variant === :eq
        collect(0:(n-1))
    elseif variant === :lambda
        [0, 1, 3, 4, 6, 7, 9, 10, 12]
    elseif variant === :dur
        [0, 1, 3, 5, 6, 7, 9, 10, 12]
    elseif variant === :moll
        [0, 2, 3, 4, 6, 7, 9, 11, 12]
    else
        throw(ArgumentError("bohlen_pierce: unknown variant :$variant"))
    end
    return Scale(name, all_steps[picks .+ 1], period)
end

"""
    golden_meantone(name = :golden_meantone; n_steps = 12) -> Scale

Golden-ratio anchored meantone — equal-step temperament built so
the ratio of the perfect fifth to whole tone is the golden ratio
φ. Yields an irrational `n_steps`-EDO-ish tuning with step size
`1200 / (n_steps · (1 + 1/φ))` cents per ... actually we use the
common convention: `step_cents = 1200 / N` where N is chosen so
the ratio of 7 steps (fifth) to 2 steps (tone) ≈ φ.

For `n_steps = 12`: step ≈ 100¢ but the fifth is 696.21¢ (Pythagorean
limit, not 700¢ as in 12-EDO).
"""
function golden_meantone(name::Symbol = :golden_meantone; n_steps::Integer = 12)
    φ = (1 + sqrt(5)) / 2
    # Solve: 7 * step / (2 * step) = φ — degenerate ratio 7/2 ≠ φ;
    # so we use the *generator* form: the fifth is `1200 / φ` cents
    # generator with n_steps repeats. This matches the classic
    # "1/φ-comma meantone" definition.
    fifth_cents = 1200.0 / φ
    cents = sort!([mod(i * fifth_cents, 1200.0) for i in 0:(n_steps-1)])
    return Scale(name, cents, 1200.0)
end

"""
    fibonacci_scale(name = :fib; n_steps = 7) -> Scale

Fibonacci ratio scale — step sizes follow the Fibonacci sequence.
Step `i` has cents = `1200 * F(i) / F(n_steps + 1)` where F is the
Fibonacci sequence. Produces unequal spacing that approaches
golden-ratio interval distribution as `n_steps` grows.
"""
function fibonacci_scale(name::Symbol = :fib; n_steps::Integer = 7)
    n_steps > 0 || throw(ArgumentError("fibonacci_scale: n_steps must be positive"))
    # Step sizes proportional to Fibonacci ratios; cumulative sum
    # gives the cents position of each degree. Starts at 0, ends
    # just before the period.
    fib = [1, 1]
    while length(fib) < n_steps + 1
        push!(fib, fib[end] + fib[end-1])
    end
    total = Float64(sum(fib[1:n_steps]))
    cents = Float64[0.0]
    acc = 0.0
    for i in 1:(n_steps - 1)
        acc += Float64(fib[i]) / total
        push!(cents, 1200.0 * acc)
    end
    return Scale(name, cents, 1200.0)
end

"""
    continued_fraction_scale(name, coeffs) -> Scale

Build a scale from convergents of a continued fraction
`[a₀; a₁, a₂, …]`. Each convergent `p/q` becomes a step at
`1200 * log2(p/q)` cents (modulo period). Produces irregular,
mathematically-motivated tunings.

Example: `continued_fraction_scale(:cf_pell, [1, 2, 2, 2])`
generates convergents 1/1, 3/2, 7/5, 17/12 → cents [0, 702, 583, 603]
which after wrap + sort yields a 4-step scale.
"""
function continued_fraction_scale(name::Symbol, coeffs::AbstractVector{<:Integer})
    length(coeffs) >= 1 || throw(ArgumentError("continued_fraction_scale: need coeffs"))
    # Compute convergents via the standard recurrence.
    h = [1, Int(coeffs[1])]
    k = [0, 1]
    for i in 2:length(coeffs)
        push!(h, Int(coeffs[i]) * h[end] + h[end-1])
        push!(k, Int(coeffs[i]) * k[end] + k[end-1])
    end
    cents = Float64[]
    for i in 2:length(h)
        push!(cents, mod(1200.0 * log2(h[i] / k[i]), 1200.0))
    end
    sort!(unique!(cents))
    cents[1] == 0.0 || pushfirst!(cents, 0.0)
    return Scale(name, cents, 1200.0)
end

"""
    stern_brocot(name = :sb; depth = 5) -> Scale

Scale built from the Stern-Brocot tree of depth `depth`. Every
mediant fraction within one octave (between 1/1 and 2/1) up to the
given depth becomes a step (in cents). Produces a dense, just-
intonation-flavoured grid that gets richer with depth.
"""
function stern_brocot(name::Symbol = :sb; depth::Integer = 5)
    depth > 0 || throw(ArgumentError("stern_brocot: depth must be positive"))
    fracs = Set{Tuple{Int,Int}}()
    push!(fracs, (1, 1))
    function _expand(p1::Int, q1::Int, p2::Int, q2::Int, d::Int)
        d == 0 && return
        m = (p1 + p2, q1 + q2)
        push!(fracs, m)
        _expand(p1, q1, m..., d - 1)
        _expand(m..., p2, q2, d - 1)
    end
    _expand(1, 1, 2, 1, depth)
    # Convert each fraction to cents above the root.
    cents = sort!(unique!([mod(1200.0 * log2(p / q), 1200.0) for (p, q) in fracs]))
    cents[1] == 0.0 || pushfirst!(cents, 0.0)
    return Scale(name, cents, 1200.0)
end

# ── Built-in library: the ~60 12-EDO scales ─────────────────────────
# Carried over from the legacy core_controls system, now reified as
# Scale values. Cents = semitone * 100. Period = 1200 (octave).

const _BUILTIN_12EDO_SCALES = Dict{Symbol,Vector{Int}}(
    # Western modes / diatonic
    :chromatic        => [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
    :major            => [0, 2, 4, 5, 7, 9, 11],
    :ionian           => [0, 2, 4, 5, 7, 9, 11],
    :minor            => [0, 2, 3, 5, 7, 8, 10],
    :natural_minor    => [0, 2, 3, 5, 7, 8, 10],
    :aeolian          => [0, 2, 3, 5, 7, 8, 10],
    :dorian           => [0, 2, 3, 5, 7, 9, 10],
    :phrygian         => [0, 1, 3, 5, 7, 8, 10],
    :lydian           => [0, 2, 4, 6, 7, 9, 11],
    :mixolydian       => [0, 2, 4, 5, 7, 9, 10],
    :locrian          => [0, 1, 3, 5, 6, 8, 10],
    :harmonic_minor   => [0, 2, 3, 5, 7, 8, 11],
    :harmonic_major   => [0, 2, 4, 5, 7, 8, 11],
    :melodic_minor    => [0, 2, 3, 5, 7, 9, 11],
    :melodic_major    => [0, 2, 4, 5, 7, 8, 10],
    :locrian_major    => [0, 2, 4, 5, 6, 8, 10],
    :super_locrian    => [0, 1, 3, 4, 6, 8, 10],

    # Pentatonic / 5-note
    :pentatonic       => [0, 2, 4, 7, 9],
    :major_pent       => [0, 2, 4, 7, 9],
    :major_pentatonic => [0, 2, 4, 7, 9],
    :minor_pent       => [0, 3, 5, 7, 10],
    :minor_pentatonic => [0, 3, 5, 7, 10],
    :ritusen          => [0, 2, 5, 7, 9],
    :egyptian         => [0, 2, 5, 7, 10],
    :kumai            => [0, 2, 3, 7, 9],
    :hirajoshi        => [0, 2, 3, 7, 8],
    :iwato            => [0, 1, 5, 6, 10],
    :chinese          => [0, 4, 6, 7, 11],
    :indian           => [0, 4, 5, 7, 10],
    :scriabin         => [0, 1, 4, 7, 9],

    # Hexatonic / 6-note
    :blues            => [0, 3, 5, 6, 7, 10],
    :whole            => [0, 2, 4, 6, 8, 10],
    :whole_tone       => [0, 2, 4, 6, 8, 10],
    :augmented        => [0, 3, 4, 7, 8, 11],
    :augmented2       => [0, 1, 4, 5, 8, 9],
    :prometheus       => [0, 2, 4, 6, 9, 10],
    :hex_major7       => [0, 2, 4, 7, 9, 11],
    :hex_dorian       => [0, 2, 3, 5, 7, 10],
    :hex_phrygian     => [0, 1, 3, 5, 8, 10],
    :hex_sus          => [0, 2, 5, 7, 9, 10],
    :hex_major6       => [0, 2, 4, 5, 7, 9],
    :hex_aeolian      => [0, 3, 5, 7, 8, 10],

    # Octatonic / 8-note (jazz)
    :diminished       => [0, 1, 3, 4, 6, 7, 9, 10],
    :diminished2      => [0, 2, 3, 5, 6, 8, 9, 11],
    :bebop_major      => [0, 2, 4, 5, 7, 8, 9, 11],
    :bebop_minor      => [0, 2, 3, 4, 5, 7, 9, 10],
    :bebop_dorian     => [0, 2, 3, 4, 5, 7, 9, 10],
    :bebop_dominant   => [0, 2, 4, 5, 7, 9, 10, 11],
    :bartok           => [0, 2, 4, 6, 7, 9, 10],

    # World / regional
    :spanish          => [0, 1, 4, 5, 7, 8, 10],
    :gypsy            => [0, 2, 3, 6, 7, 8, 10],
    :hungarian_minor  => [0, 2, 3, 6, 7, 8, 11],
    :hungarian_major  => [0, 3, 4, 6, 7, 9, 10],
    :romanian_minor   => [0, 2, 3, 6, 7, 9, 10],
    :ukrainian_dorian => [0, 2, 3, 6, 7, 9, 10],
    :neapolitan_minor => [0, 1, 3, 5, 7, 8, 11],
    :neapolitan_major => [0, 1, 3, 5, 7, 9, 11],
    :persian          => [0, 1, 4, 5, 6, 8, 11],
    :arabic           => [0, 2, 4, 5, 6, 8, 10],
    :byzantine        => [0, 1, 4, 5, 7, 8, 11],
    :jewish           => [0, 1, 4, 5, 7, 8, 10],
    :japanese         => [0, 1, 5, 7, 8],
    :enigmatic        => [0, 1, 4, 6, 8, 10, 11],

    # Indian ragas
    :bhairav          => [0, 1, 4, 5, 7, 8, 11],
    :ahirbhairav      => [0, 1, 4, 5, 7, 9, 10],
    :marva            => [0, 1, 4, 6, 7, 9, 11],
    :purvi            => [0, 1, 4, 6, 7, 8, 11],
    :todi             => [0, 1, 3, 6, 7, 8, 11],
)

for (name, steps) in _BUILTIN_12EDO_SCALES
    register_scale!(Scale(name, Float64.(steps) .* 100.0, 1200.0))
end
