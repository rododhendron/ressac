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
        s = ugen(white(), :Pluck, 1, 0.5, 0.4, 0.95)      # hors macro : la forme directe, le signal d'abord
        @test s isa Sig
        @test s.code == "Pluck.ar(WhiteNoise.ar, 1, 0.5, 0.4, 0.95)"
    end

    @testset "direct and curried forms produce identical Sig" begin
        # `saw` is exported by both Ressac (continuous signal) and
        # SynthDSL (Saw.ar UGen); qualify to avoid Main-scope ambiguity.
        a = ugen(:Decimator, SynthDSL.saw(220), 8000, 8)
        b = ugen(SynthDSL.saw(220), :Decimator, 8000, 8)
        @test a.code == b.code
    end

    @testset "rate=:kr produces control-rate call" begin
        s = ugen(:LFNoise2, 4; rate = :kr)
        @test s.code == "LFNoise2.kr(4)"
    end

    @testset "rate keyword applies through curry too" begin
        s = ugen(:LFNoise2, 4; rate = :kr)
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
        s = rlpf(ugen(white(), :Pluck, 1, 0.5, 0.4, 0.95), 800, 0.3)
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
        s = rlpf(SynthDSL.lorenz(8000), 800, 0.3)
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
        sig = Core.eval(SynthDSL, SynthDSL._elixir_pipes(Meta.parse(SynthDSL._dsl_preprocess(src))))   # comme dans @synth
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
        s = SynthDSL.env_gen(SynthDSL.saw(:freq), e; gate=:gate,
            level_scale=0.8, level_bias=0.1, time_scale=2, done_action=2)
        @test occursin("EnvGen.kr(", s.code)
        @test occursin("gate", s.code)            # gate arg threaded
        @test occursin("0.8", s.code)             # level_scale
        @test occursin("0.1", s.code)             # level_bias
        @test occursin("doneAction: 2", s.code)
    end

    @testset "env_gen accepts a raw Env.<shape> Sig" begin
        s = SynthDSL.env_gen(SynthDSL.sin_osc(:freq), SynthDSL.Sig("Env.perc(0.01, 1)"))
        @test occursin("Env.perc(0.01, 1)", s.code)
        @test occursin("EnvGen.kr(", s.code)
    end

    @testset "env_gen default done_action frees the synth" begin
        e = SynthDSL.env([0, 1, 0], [0.01, 0.5])
        s = SynthDSL.env_gen(SynthDSL.saw(:freq), e)
        @test occursin("doneAction: 2", s.code)
    end
end

@testset "mises en forme — le signal d'abord, et la puissance" begin
    S = Ressac.SynthDSL
    s = S.saw(:freq)
    @test S.clip(s).code == "Saw.ar(freq).clip(-1, 1)"
    @test S.clip(s, 0.5).code == "Saw.ar(freq).clip(0.5, 1)"
    @test S.tanh_drive(s, 2).code == "((Saw.ar(freq)) * 2).tanh"
    @test S.soft_clip(s).code == "Saw.ar(freq).softclip"
    @test S.free_verb(s, 0.3, 0.8).code == "FreeVerb.ar(Saw.ar(freq), 0.3, 0.8, 0.5)"
    # un paramètre qui est un signal : aucune ambiguïté, le signal est toujours le premier
    q = S.saw(:freq)
    @test S.round_q(:freq, q).code == "(freq).round($(q.code))"
    @test S.fold2(S.saw(:freq), S.sin_osc(3)).code == "(Saw.ar(freq)).fold2(SinOsc.ar(3, 0))"
    lfo = S.lfo(0.2; low = 300, high = 2000)
    @test S.low_pass(s, lfo).code == "LPF.ar($(s.code), $(lfo.code))"
    # un nombre ou un contrôle en entrée ; ugen se pipe
    @test S.clip2(4.0, 1.0).code == "(4.0).clip2(1.0)"
    @test S.ugen(s, :RLPF, 800, 0.3).code == "RLPF.ar(Saw.ar(freq), 800, 0.3)"
    # puissance et moins unaire
    @test (S.sin_osc(:freq) ^ 2).code == "(SinOsc.ar(freq, 0) ** 2)"
    @test (:freq ^ 2).code == "(freq ** 2)"
    @test (-(:freq)).code == "(freq.neg)"
    # par le chemin de la pane : T évalue tout le fichier dans SynthDSL
    for body in ("saw(:freq) |> clip", "saw(:freq) |> soft_clip", "sin_osc(:freq) ^ 2", "saw(:freq) |> clip(-0.5, 0.5) |> soft_clip")
        src = "@synth :probe (freq=220, sustain=0.5) " * body
        @test (Core.eval(S, S._dsl_parse_all(src)); true)
    end
end

@testset "une étape sans signal — message clair, pas de MethodError" begin
    S = Ressac.SynthDSL
    err = try
        Core.eval(S, S._dsl_parse_all("@synth :probe (freq=220) &low_pass(&1, 800)"))   # une capture, pas un signal
        nothing
    catch e; e end
    @test err isa ArgumentError && occursin("le signal d'abord", sprint(showerror, err))
end

@testset "ugen() — les noms-méthodes du catalogue rendent du SC valide" begin
    S = Ressac.SynthDSL
    @test S.ugen(:Midicps, 4.0).code == "(4.0).midicps"
    @test S.ugen(:Cubed, S.saw(:freq)).code == "(Saw.ar(freq)).cubed"
    @test S.ugen(:Clip, S.saw(:freq), -0.5, 0.5).code == "(Saw.ar(freq)).clip(-0.5, 0.5)"
    @test S.ugen(:EnvPerc, 0.01, 0.4).code == "Env.perc(0.01, 0.4)"
    @test S.ugen(:Div, S.saw(:freq), 2).code == "(Saw.ar(freq) / 2)"
    @test S.ugen(:Saw, :freq).code == "Saw.ar(freq)"                  # les vraies classes ne changent pas
    # le fichier exporté par l'ancien exporteur (Midicps, Cubed en ugen()) rend du SC sans classe inconnue
    old = "@synth :t (freq=166.0, sustain=0.5) begin\n    n1 = ugen(:Saw, :freq)\n    n2 = 4.0 |> clip2(1.0)\n" *
          "    n8 = ugen(:Midicps, 4.0)\n    n9 = ugen(:Cubed, n8)\n    n10 = ugen(:LFPulse, n9, 0.0, 0.5; rate = :kr)\n" *
          "    ugen(:RLPF, n1 + n2, 400.0, n10)\nend"
    sc = Ressac.synth_source(:t, Core.eval(S, S._elixir_pipes(Expr(:let, Expr(:block), S._dsl_synth_expr(old).args[end]))))
    @test occursin("(4.0).midicps", sc) && occursin(".cubed", sc) && !occursin("Midicps.ar", sc)
end


@testset "le |> d'Elixir dans @synth — premier argument, _, fonction nue, kwargs, les tiennes" begin
    S = Ressac.SynthDSL
    P = S._elixir_pipes
    @test P(:(x |> f(a, b))) == :(f(x, a, b))
    @test P(:(x |> f(a, _))) == :(f(a, x))                                  # _ ou &1 : la place de la valeur
    @test P(:(x |> f(a, &1))) == :(f(a, x))
    @test P(:(x |> f)) == :(f(x))
    @test P(:(x |> f(a; k = 1))) == :(f(x, a; k = 1))
    @test P(:(x |> f(a) |> g(b))) == :(g(f(x, a), b))
    @test P(:(begin y = x |> f(1); y end)).args[2] == :(y = f(x, 1))      # récursif dans un bloc
    @test P(:(x |> (z -> z * 2))) == :(x |> (z -> z * 2))                   # une fermeture : Julia
    @test P(:(x |> M.f)) == :(M.f(x))
    # la capture : &f(&1, a) est x -> f(x, a) ; &(&1 + &2) prend deux arguments
    cap = P(:(&rlpf(&1, 800, 0.3)))
    @test cap.head === :-> && length(cap.args[1].args) == 1
    fn = Core.eval(S, cap)
    @test fn(S.saw(:freq)).code == "RLPF.ar(Saw.ar(freq), 800, 0.3)"
    two = Core.eval(S, P(:(&(&1 + &2))))
    @test two(1, 2) == 3
    drive = Core.eval(S, P(:(begin d = &tanh_drive(&1, 2); saw(:freq) |> d end)))
    @test drive.code == "((Saw.ar(freq)) * 2).tanh"
    # de bout en bout, par T : filtres avec un LFO en paramètre, ugen pipable, ma propre fonction
    Core.eval(S, :(mon_drive(s, k) = tanh_drive(s, k)))
    for body in ("saw(:freq) |> low_pass(lfo(0.2; low = 300, high = 2000)) |> mon_drive(3)",
                 ":freq |> round_q(saw(:freq; ))",
                 "saw(:freq) |> ugen(:RLPF, 800, 0.3) |> ugen(:Cubed) |> safe(0.9)",
                 "saw(:freq) |> env_perc(0.01, 0.4; level = 0.8) |> stereo_pan(0.2)",
                 "4.0 |> clip2(1.0) |> ugen(:LFPulse, _, 0.0, 0.5; rate = :kr)")
        src = "@synth :probe (freq=220, sustain=0.5) " * replace(body, "saw(:freq; )" => "saw(:freq)")
        sc = Core.eval(S, S._dsl_parse_all(src))
        @test sc isa String && occursin("SynthDef", sc)
    end
    sc = Core.eval(S, S._dsl_parse_all("@synth :probe (freq=220) saw(:freq) |> low_pass(lfo(0.2; low = 300, high = 2000))"))
    @test occursin("LPF.ar(Saw.ar(freq), SinOsc.kr(0.2).range(300, 2000))", sc)
    sc = Core.eval(S, S._dsl_parse_all("@synth :probe (freq=220) saw(:freq) |> ugen(:Pan2, _, 0.2, 1)"))   # _ : appel direct
    @test occursin("Pan2.ar(Saw.ar(freq), 0.2, 1)", sc)
end
