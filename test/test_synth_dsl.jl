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

@testset "synth DSL — leading-pipe + bare kw group" begin
    @testset "_dsl_preprocess joins leading |> onto previous line" begin
        src = "sin_osc(:freq)\n  |> rlpf(800)\n  |> tanh_drive(3)"
        out = SynthDSL._dsl_preprocess(src)
        @test !occursin("\n  |>", out)        # no orphan leading pipe
        @test occursin("sin_osc(:freq) |> rlpf(800) |> tanh_drive(3)", out)
    end

    @testset "leading-pipe DSL parses + evals" begin
        src = """
        sin_osc(:freq)
          |> rlpf(800, 0.3)
          |> tanh_drive(3)
        """
        sig = Core.eval(SynthDSL, Meta.parse(SynthDSL._dsl_preprocess(src)))
        @test occursin("SinOsc.ar", sig.code)
        @test occursin("RLPF.ar", sig.code)
        @test occursin(".tanh", sig.code)
    end

    @testset "bare (key=val) opts without trailing comma works" begin
        # _normalize_kw_group wraps a bare assignment into a 1-tuple
        # so `(auto_env=false)` behaves like `(auto_env=false,)`.
        src = """
        @synth :baretest (freq=65) (auto_env=false) begin
          sin_osc(:freq)
        end
        """
        # Should parse + eval without a BoundsError.
        @test (Core.eval(SynthDSL, Meta.parse(src)); true)
    end
end

@testset "synth DSL — env() + env_gen() raw envelope control" begin
    @testset "env() builds an Env spec Sig" begin
        e = SynthDSL.env([0, 1, 0], [0.01, 0.5])
        @test occursin("Env([0, 1, 0], [0.01, 0.5]", e.code)
        @test occursin("\\lin", e.code)
    end

    @testset "env_gen exposes every EnvGen arg" begin
        e = SynthDSL.env([0, 1, 0], [0.01, 0.5])
        s = SynthDSL.saw(:freq) |> SynthDSL.env_gen(e; gate=:gate,
            level_scale=0.8, level_bias=0.1, time_scale=2, done_action=2)
        @test occursin("EnvGen.kr(", s.code)
        @test occursin("gate", s.code)            # gate arg threaded
        @test occursin("0.8", s.code)             # level_scale
        @test occursin("0.1", s.code)             # level_bias
        @test occursin("doneAction: 2", s.code)
    end

    @testset "env_gen accepts a raw Env.<shape> Sig" begin
        s = SynthDSL.sin_osc(:freq) |>
            SynthDSL.env_gen(SynthDSL.Sig("Env.perc(0.01, 1)"))
        @test occursin("Env.perc(0.01, 1)", s.code)
        @test occursin("EnvGen.kr(", s.code)
    end

    @testset "env_gen default done_action frees the synth" begin
        e = SynthDSL.env([0, 1, 0], [0.01, 0.5])
        s = SynthDSL.saw(:freq) |> SynthDSL.env_gen(e)
        @test occursin("doneAction: 2", s.code)
    end
end
