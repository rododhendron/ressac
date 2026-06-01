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
