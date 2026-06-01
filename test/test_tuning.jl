# Unit tests for src/core_tuning.jl — the Scale type, degree math,
# and the registry. Higher-level constructors (edo, from_ratios,
# bohlen_pierce, etc.) are tested in test_tuning_constructors.jl.

using Test
using Ressac

@testset "Scale construction validates invariants" begin
    # OK — minimal valid
    s = Ressac.Scale(:two, [0.0, 600.0], 1200.0)
    @test s.name === :two
    @test s.cents == [0.0, 600.0]
    @test s.period_cents == 1200.0

    # Empty cents rejected
    @test_throws ArgumentError Ressac.Scale(:bad, Float64[], 1200.0)
    # Must start at 0
    @test_throws ArgumentError Ressac.Scale(:bad, [100.0, 700.0], 1200.0)
    # Must be strictly increasing
    @test_throws ArgumentError Ressac.Scale(:bad, [0.0, 700.0, 700.0], 1200.0)
    @test_throws ArgumentError Ressac.Scale(:bad, [0.0, 700.0, 500.0], 1200.0)
    # Period must be > 0
    @test_throws ArgumentError Ressac.Scale(:bad, [0.0], 0.0)
    # Last cent must be < period
    @test_throws ArgumentError Ressac.Scale(:bad, [0.0, 1200.0], 1200.0)
end

@testset "scale_to_semitones — integer degrees in 12-EDO major" begin
    s = Ressac.Scale(:major, [0.0, 200.0, 400.0, 500.0, 700.0, 900.0, 1100.0], 1200.0)
    @test Ressac.scale_to_semitones(s, 0) == 0.0     # C
    @test Ressac.scale_to_semitones(s, 1) == 2.0     # D
    @test Ressac.scale_to_semitones(s, 2) == 4.0     # E
    @test Ressac.scale_to_semitones(s, 4) == 7.0     # G
    @test Ressac.scale_to_semitones(s, 6) == 11.0    # B
end

@testset "scale_to_semitones — wraps into the next period" begin
    s = Ressac.Scale(:major, [0.0, 200.0, 400.0, 500.0, 700.0, 900.0, 1100.0], 1200.0)
    @test Ressac.scale_to_semitones(s, 7) == 12.0    # C one octave up
    @test Ressac.scale_to_semitones(s, 8) == 14.0    # D one octave up
    @test Ressac.scale_to_semitones(s, 14) == 24.0   # C two octaves up
end

@testset "scale_to_semitones — negative degrees walk down" begin
    s = Ressac.Scale(:major, [0.0, 200.0, 400.0, 500.0, 700.0, 900.0, 1100.0], 1200.0)
    @test Ressac.scale_to_semitones(s, -1) == -1.0   # B below root (1100¢ - 1200¢)
    @test Ressac.scale_to_semitones(s, -7) == -12.0  # C one octave down
    # degree -8 = degree -7 minus one scale step. -7 is the root one
    # period down (-1200¢ = -12 semitones); one more step down lands
    # on the 7th of the scale in the period below — 1100¢ - 2400¢ =
    # -1300¢ = -13 semitones. (Matches TidalCycles' divMod convention.)
    @test Ressac.scale_to_semitones(s, -8) ≈ -13.0
end

@testset "scale_to_semitones — fractional degree interpolates linearly" begin
    s = Ressac.Scale(:major, [0.0, 200.0, 400.0, 500.0, 700.0, 900.0, 1100.0], 1200.0)
    # Halfway between root (0¢) and 2nd (200¢) → 100¢ = 1 semitone
    @test Ressac.scale_to_semitones(s, 0.5) ≈ 1.0
    # 0.25 of the way between 4th (700¢) and 5th (900¢) → 750¢
    @test Ressac.scale_to_semitones(s, 4.25) ≈ 7.5
    # Fractional that crosses the period boundary still interpolates
    # between adjacent scale steps (6 → 7 = 1100¢ → 1200¢)
    @test Ressac.scale_to_semitones(s, 6.5) ≈ 11.5
end

@testset "scale_to_semitones — non-octave period (Bohlen-Pierce)" begin
    # Bohlen-Pierce equal: 13 equal steps per tritave (3:1 = 1901.955¢)
    n = 13
    period = 1200.0 * log2(3.0)
    cents = [period * i / n for i in 0:(n-1)]
    s = Ressac.Scale(:bp_eq, cents, period)
    @test Ressac.scale_to_semitones(s, 0) == 0.0
    # Degree 13 = one tritave up = 1901.955¢ → 19.02 semitones
    @test Ressac.scale_to_semitones(s, n) ≈ period / 100 atol=1e-6
    # Degree -1 = one step below root = -period/n ≈ -1.464 semitones
    @test Ressac.scale_to_semitones(s, -1) ≈ -(period / n) / 100 atol=1e-6
end

@testset "Registry — register / lookup / list" begin
    sym = Symbol("ui-tuning-test-$(rand(UInt32))")
    @test Ressac.lookup_scale(sym) === nothing
    s = Ressac.Scale(sym, [0.0, 500.0], 1200.0)
    Ressac.register_scale!(s)
    @test Ressac.lookup_scale(sym) === s
    @test Ressac.lookup_scale(String(sym)) === s   # accepts AbstractString
    @test sym in Ressac.list_scales()
    delete!(Ressac._SCALES, sym)
end

@testset "Registry — register_scale! warns on shadow" begin
    sym = Symbol("ui-tuning-shadow-$(rand(UInt32))")
    s1 = Ressac.Scale(sym, [0.0, 600.0], 1200.0)
    s2 = Ressac.Scale(sym, [0.0, 300.0, 900.0], 1200.0)
    Ressac.register_scale!(s1)
    @test_logs (:warn, r"shadowed") Ressac.register_scale!(s2)
    @test Ressac.lookup_scale(sym) === s2
    delete!(Ressac._SCALES, sym)
end

@testset "length(::Scale) returns the degree count" begin
    s = Ressac.Scale(:five, [0.0, 200.0, 400.0, 700.0, 900.0], 1200.0)
    @test length(s) == 5
end

# ── note() control — direct chromatic pitch ─────────────────────────

@testset "note(x) sets :note as overwrite control" begin
    p = pure(:saw) |> note(60.5)
    evs = p(0//1, 1//1)
    @test length(evs) == 1
    cm = evs[1].value
    @test cm[:note] == 60.5
end

@testset "note() composes — second wins, last-wins semantics" begin
    p = pure(:saw) |> note(60) |> note(72)
    cm = p(0//1, 1//1)[1].value
    @test cm[:note] == 72
end

# ── scale() control — degree → :note ────────────────────────────────

@testset "scale(s) maps degree pattern to :note semitones" begin
    s = Ressac.lookup_scale(:major)
    p = "0 2 4 7" |> Ressac.scale(s)
    evs = p(0//1, 1//1)
    @test length(evs) == 4
    notes = [ev.value[:note] for ev in evs]
    @test notes ≈ [0.0, 4.0, 7.0, 12.0]   # major scale degrees in semitones
end

@testset "scale(:symbol) resolves via registry" begin
    p = "0 2 4 7" |> Ressac.scale(:major)
    notes = [ev.value[:note] for ev in p(0//1, 1//1)]
    @test notes ≈ [0.0, 4.0, 7.0, 12.0]
end

@testset "scale() throws on unknown symbol" begin
    @test_throws ArgumentError Ressac.scale(:totally_made_up_scale_zzz)
end

@testset "scale() composes with gain — preserves controls" begin
    p = "0 2 4" |> Ressac.scale(:major) |> gain(0.5)
    evs = p(0//1, 1//1)
    @test all(ev.value[:gain] == 0.5 for ev in evs)
    @test [ev.value[:note] for ev in evs] ≈ [0.0, 4.0, 7.0]
end

@testset "scale() strips :s when value was actually a degree symbol" begin
    # When gain() lifts "0 2 4" through _lift_to_control, :s gets
    # set to :0/:2/:4 — those are not sample names, they were
    # degree markers. scale() must clean them up.
    p = "0 2 4" |> gain(0.5) |> Ressac.scale(:major)
    evs = p(0//1, 1//1)
    @test all(!haskey(ev.value, :s) for ev in evs)
    @test [ev.value[:note] for ev in evs] ≈ [0.0, 4.0, 7.0]
end

@testset "scale() leaves non-numeric :s alone (real sample names)" begin
    # When :s carries a true sample name (not a numeric-string), the
    # value isn't a degree — scale() must NOT strip it nor set :note.
    p = pure(:bd) |> gain(0.5) |> Ressac.scale(:major)
    evs = p(0//1, 1//1)
    @test evs[1].value[:s] === :bd
    @test evs[1].value[:gain] == 0.5
    @test !haskey(evs[1].value, :note)
end

@testset "scale() supports xenharmonic — Bohlen-Pierce period" begin
    bp = Ressac.bohlen_pierce(:bp_lambda_test; variant = :lambda)
    p = "0 9" |> Ressac.scale(bp)
    notes = [ev.value[:note] for ev in p(0//1, 1//1)]
    # Degree 0 = root (0 semitones); degree 9 = one tritave up
    # = period_cents / 100 = log2(3) * 12 ≈ 19.02 semitones
    @test notes[1] ≈ 0.0
    @test notes[2] ≈ bp.period_cents / 100 atol = 1e-6
end

# ── transpose_cents / scale_stretch / bend (Step D) ─────────────────

@testset "transpose_cents shifts :note by c/100 semitones" begin
    p = "0 2 4" |> Ressac.scale(:major) |> Ressac.transpose_cents(50)
    notes = [ev.value[:note] for ev in p(0//1, 1//1)]
    @test notes ≈ [0.5, 4.5, 7.5]
end

@testset "transpose_cents composes — stacks additively" begin
    p = "0" |> Ressac.scale(:major) |>
        Ressac.transpose_cents(100) |> Ressac.transpose_cents(200)
    @test p(0//1, 1//1)[1].value[:note] ≈ 3.0
end

@testset "transpose_cents seeds :note when not yet set" begin
    p = pure(:saw) |> Ressac.transpose_cents(700)
    @test p(0//1, 1//1)[1].value[:note] ≈ 7.0
end

@testset "scale_stretch returns a stretched Scale" begin
    major = Ressac.lookup_scale(:major)
    big = Ressac.scale_stretch(major, 2.0)
    @test big.period_cents ≈ 2 * major.period_cents
    @test big.cents ≈ 2 .* major.cents
    @test big.name === :major_stretched

    small = Ressac.scale_stretch(major, 0.5)
    @test small.period_cents ≈ 0.5 * major.period_cents
end

@testset "scale_stretch rejects non-positive factor" begin
    major = Ressac.lookup_scale(:major)
    @test_throws ArgumentError Ressac.scale_stretch(major, 0)
    @test_throws ArgumentError Ressac.scale_stretch(major, -1.5)
end

@testset "bend adds cents from a continuous curve to :note" begin
    # Curve: constant 50 cents via range_pat(50, 50, sine())
    # — sine swings -1..1, range squashes to [50, 50], so all
    # samples are 50¢. Trivial but verifies the wiring.
    curve = Ressac.range_pat(50.0, 50.0, sine())
    p = "0 2" |> Ressac.scale(:major) |> Ressac.bend(curve)
    notes = [ev.value[:note] for ev in p(0//1, 1//1)]
    @test all(abs.(notes .- (notes[1])) .< 4.1)   # major 3rd ≈ 4 semitones gap
    # Both notes are :note + 0.5 semitones
    @test notes ≈ [0.5, 4.5]
end
