# Tests for the Synth DSL — generic UGen escape hatch `ugen()`.
# Wrapped UGens (saw, sin_osc, …) are exercised indirectly through
# the @synth-based tests; this file pins down `ugen()` specifically
# since it is the public extension point for un-wrapped UGens.

@testset "synth DSL — ugen()" begin
    using Ressac.SynthDSL

    @testset "direct form: name first, args follow" begin
        s = ugen(:Pluck, white(), 1, 0.5, 0.4, 0.95)
        @test s isa Sig
        @test s.code == "Pluck.ar(WhiteNoise.ar, 1, 0.5, 0.4, 0.95)"
    end

    @testset "direct form: no args → bare UGen call" begin
        s = ugen(:WhiteNoise)
        @test s.code == "WhiteNoise.ar()"
    end

    @testset "curried form: name piped in" begin
        s = :Pluck |> ugen(white(), 1, 0.5, 0.4, 0.95)
        @test s isa Sig
        @test s.code == "Pluck.ar(WhiteNoise.ar, 1, 0.5, 0.4, 0.95)"
    end

    @testset "direct and curried forms produce identical Sig" begin
        # `saw` is exported by both Ressac (continuous signal) and
        # SynthDSL (Saw.ar UGen); qualify to avoid Main-scope ambiguity.
        a = ugen(:Decimator, SynthDSL.saw(220), 8000, 8)
        b = :Decimator |> ugen(SynthDSL.saw(220), 8000, 8)
        @test a.code == b.code
    end

    @testset "rate=:kr produces control-rate call" begin
        s = ugen(:LFNoise2, 4; rate = :kr)
        @test s.code == "LFNoise2.kr(4)"
    end

    @testset "rate keyword applies through curry too" begin
        s = :LFNoise2 |> ugen(4; rate = :kr)
        @test s.code == "LFNoise2.kr(4)"
    end

    @testset "Symbol args render unquoted (SC param refs)" begin
        # When a Sig references a synth control like :freq, it should
        # render as the bare name `freq`, matching the existing wrappers.
        s = ugen(:Saw, :freq)
        @test s.code == "Saw.ar(freq)"
    end

    @testset "composes with wrapped UGens via |>" begin
        # Build a Pluck and feed it into rlpf — proves the resulting
        # Sig threads through curried filters like any other UGen.
        s = (:Pluck |> ugen(white(), 1, 0.5, 0.4, 0.95)) |> rlpf(800, 0.3)
        @test occursin("Pluck.ar(WhiteNoise.ar", s.code)
        @test occursin("RLPF.ar", s.code)
    end
end

@testset "synth DSL — chaotic / nonlinear sources" begin
    using Ressac.SynthDSL

    @testset "each wrapper renders a Sig with the expected UGen name" begin
        @test SynthDSL.lorenz().code      |> s -> startswith(s, "LorenzL.ar(")
        @test SynthDSL.henon().code       |> s -> startswith(s, "HenonL.ar(")
        @test SynthDSL.logistic().code    |> s -> startswith(s, "Logistic.ar(")
        @test SynthDSL.standard_map().code |> s -> startswith(s, "StandardL.ar(")
        @test SynthDSL.latoo().code       |> s -> startswith(s, "LatoocarfianL.ar(")
        @test SynthDSL.lincong().code     |> s -> startswith(s, "LinCongL.ar(")
        @test SynthDSL.quad().code        |> s -> startswith(s, "QuadL.ar(")
        @test SynthDSL.fbsine().code      |> s -> startswith(s, "FBSineL.ar(")
        @test SynthDSL.gbman().code       |> s -> startswith(s, "GbmanL.ar(")
        @test SynthDSL.cusp().code        |> s -> startswith(s, "CuspL.ar(")
    end

    @testset "lorenz: all 8 args appear in order" begin
        s = SynthDSL.lorenz(8000, 10, 28, 2.5, 0.05, 0.1, 0.0, 0.0)
        @test s.code == "LorenzL.ar(8000, 10, 28, 2.5, 0.05, 0.1, 0.0, 0.0)"
    end

    @testset "logistic: paramA comes BEFORE freq (matches SC convention)" begin
        # In SC, `Logistic.ar(paramA, freq, x0)` — our wrapper keeps the
        # same order via keyword defaults.
        s = SynthDSL.logistic(2000, 3.9, 0.5)
        @test s.code == "Logistic.ar(3.9, 2000, 0.5)"
    end

    @testset "compose with filters and envelope" begin
        s = SynthDSL.lorenz(8000) |> rlpf(800, 0.3)
        @test occursin("LorenzL.ar(", s.code)
        @test occursin("RLPF.ar", s.code)
    end

    @testset "chaos UGen can receive a synth control symbol as arg" begin
        # In @synth context users wire freq/sustain controls in; verify
        # Symbol args render as bare names (matching saw/sin_osc behavior).
        s = SynthDSL.lorenz(:freq)
        @test occursin("LorenzL.ar(freq,", s.code)
    end
end
