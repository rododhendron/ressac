# Expression SC → Genome (sc_expr_parse.jl) et genome_from_dsl par
# évaluation du corps : la sculpture et l'explication lisent le vrai son.
using Test
using Ressac

_names(g) = sort([String(n.ugen) for n in values(g.nodes)])
_out(g) = g.nodes[g.output_id]
const _CTL = (:freq, :sustain, :gain, :release)

@testset "expression SC — appels, rates, arithmétique, postfixes" begin
    g = Ressac.genome_from_sc("Saw.ar(freq)", _CTL)
    @test _names(g) == ["Saw"] && _out(g).args == [Ressac.ControlRef(:freq)]
    g = Ressac.genome_from_sc("RLPF.ar(Saw.ar(freq), 800, 0.3)", _CTL)
    @test _out(g).ugen === :RLPF && _out(g).args[2] == Ressac.ConstArg(800.0) && _out(g).args[1] isa Ressac.NodeRef
    # .kr connues du catalogue, .kr génériques, appel sans parenthèses
    g = Ressac.genome_from_sc("SinOsc.kr(0.2)", _CTL); @test _out(g).ugen === :SinOscKR && _out(g).rate === :kr
    g = Ressac.genome_from_sc("LFNoise1.kr(4)", _CTL); @test _out(g).ugen === :LFNoise1 && _out(g).rate === :kr
    g = Ressac.genome_from_sc("WhiteNoise.ar", _CTL); @test _out(g).ugen === :WhiteNoise && isempty(_out(g).args)
    # arithmétique : * → MulAdd, + reprend le terme additif, - et / sur constantes
    g = Ressac.genome_from_sc("((Saw.ar(freq) * 0.5) + 0.1)", _CTL)
    @test _names(g) == ["MulAdd", "Saw"] && _out(g).args[2] == Ressac.ConstArg(0.5) && _out(g).args[3] == Ressac.ConstArg(0.1)
    g = Ressac.genome_from_sc("(Saw.ar(freq) + Pulse.ar(freq))", _CTL); @test _out(g).ugen === :Mix
    g = Ressac.genome_from_sc("(2 * Saw.ar(freq))", _CTL); @test _out(g).ugen === :MulAdd && _out(g).args[1] isa Ressac.NodeRef
    g = Ressac.genome_from_sc("(Saw.ar(freq) / 4)", _CTL); @test _out(g).ugen === :MulAdd && _out(g).args[2] == Ressac.ConstArg(0.25)
    g = Ressac.genome_from_sc("(Saw.ar(freq) - 0.5)", _CTL); @test _out(g).ugen === :Mix && _out(g).args[2] == Ressac.ConstArg(-0.5)
    g = Ressac.genome_from_sc("-Saw.ar(freq)", _CTL); @test _out(g).ugen === :MulAdd && _out(g).args[2] == Ressac.ConstArg(-1.0)
    @test Ressac.genome_from_sc("(1 + 2) * 3", _CTL) === nothing            # pas un nœud
    # postfixes : .tanh, .fold2, .range, .softclip (générique), .value
    g = Ressac.genome_from_sc("((Saw.ar(freq)) * 2).tanh", _CTL); @test _out(g).ugen === :Tanh
    g = Ressac.genome_from_sc("(Saw.ar(freq)).fold2(0.7)", _CTL); @test _out(g).ugen === :Fold2 && _out(g).args[2] == Ressac.ConstArg(0.7)
    g = Ressac.genome_from_sc("SinOsc.kr(0.2).range(300, 800)", _CTL)
    @test _out(g).ugen === :MulAdd && _out(g).args[2] == Ressac.ConstArg(250.0) && _out(g).args[3] == Ressac.ConstArg(550.0)
    g = Ressac.genome_from_sc("Saw.ar(freq).softclip", _CTL); @test _out(g).ugen === :Softclip
    # mots-clés SC sautés, Env.perc → EnvPerc, tableaux → première voie, \\sym, fb
    g = Ressac.genome_from_sc("(Saw.ar(freq) * EnvGen.kr(Env.perc(0.01, 0.4, 1, -4), doneAction: 2))", _CTL)
    @test "EnvGen" in _names(g) && "EnvPerc" in _names(g)
    g = Ressac.genome_from_sc("Pan2.ar([Saw.ar(freq), Pulse.ar(freq)], 0, 1)", _CTL); @test _out(g).args[1] isa Ressac.NodeRef && "Saw" in _names(g)
    g = Ressac.genome_from_sc("Env.linen(0.01, sustain, 0.1, 1, \\lin)", _CTL); @test _out(g).ugen === :EnvLinen
    g = Ressac.genome_from_sc("(Saw.ar(fb) + fb)", _CTL); @test count(==("FbIn"), _names(g)) == 1
    # bloc opaque
    g = Ressac.genome_from_sc("{ SinOsc.ar(freq) }.value", _CTL); @test _names(g) == ["Raw"]
    # chaîne de sécurité retirée
    g = Ressac.genome_from_sc("Limiter.ar(LeakDC.ar(Sanitize.ar(Saw.ar(freq))), 0.95)", _CTL); @test _out(g).ugen === :Saw
    # un identifiant inconnu vaut 0, pi vaut pi
    g = Ressac.genome_from_sc("SinOsc.ar(freq, pi)", _CTL); @test _out(g).args[2] == Ressac.ConstArg(Float64(pi))
    g = Ressac.genome_from_sc("SinOsc.ar(machin)", _CTL); @test _out(g).args[1] == Ressac.ConstArg(0.0)
end

@testset "genome_from_dsl — le vocabulaire réel du DSL" begin
    g = Ressac.genome_from_dsl("@synth :a (freq=220, sustain=0.5) sin_osc(:freq)")
    @test _names(g) == ["SinOsc"] && Ressac.control(g, :freq) == 220.0
    @test any(l -> occursin("1 source", l), Ressac.explain_genome(g))
    g = Ressac.genome_from_dsl("@synth :acid (freq=60, sustain=0.3) saw(:freq) |> rlpf(line(3000, 500, :sustain), 0.18) |> tanh_drive(2)")
    @test _names(g) == ["Line", "MulAdd", "RLPF", "Saw", "Tanh"] && _out(g).ugen === :Tanh
    @test any(l -> occursin("saturation", l), Ressac.explain_genome(g))
    src = "@synth :p (freq=220) begin\n  a = saw(:freq) + saw(:freq * 1.007)\n" *
          "  a |> low_pass(lfo(0.2; low = 300, high = 2000)) |> env_perc(0.01, 0.4) |> stereo_pan(0.2)\nend\n# fin\n"
    g = Ressac.genome_from_dsl(src)
    @test count(==("Saw"), _names(g)) == 2 && "SinOscKR" in _names(g) && "LPF" in _names(g) && _out(g).ugen === :Pan2
    # feedback avec les wrappers, pas seulement la forme exportée
    g = Ressac.genome_from_dsl("@synth :f (freq=200) feedback() do fb\n  saw(:freq) + fb * 0.3\nend")
    @test "FbIn" in _names(g) && _out(g).ugen === :Mix
    # SC brut : un bloc opaque, que la sculpture refuse en amont
    g = Ressac.genome_from_dsl("@synth :raw (freq=220) SynthDSL.Sig(\"{ SinOsc.ar(freq) }.value\")")
    @test g !== nothing && _names(g) == ["Raw"]
    # ce qui ne s'évalue pas donne nothing, sans exception
    @test Ressac.genome_from_dsl("@synth :b (freq=220) pas_un_wrapper(:freq)") === nothing
    @test Ressac.genome_from_dsl("@synth :c (freq=220) 42") === nothing
    # l'export DSL d'un génome reste lisible (aller-retour)
    g0 = Ressac.Genome()
    s = Ressac.add_node!(g0, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
    f = Ressac.add_node!(g0, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s), Ressac.ConstArg(800.0), Ressac.ConstArg(0.3)])
    g0.output_id = f
    g1 = Ressac.genome_from_dsl(Ressac.render_dsl(g0, :foo))
    @test Ressac.render_synthdef(g1, :x) == Ressac.render_synthdef(g0, :x)
end

@testset "studio — un synth écrit à la main a des knobs nommés et une explication repliée" begin
    g = Ressac.genome_from_dsl("@synth :acid (freq=60, sustain=0.3) saw(:freq) |> rlpf(line(3000, 500, :sustain), 0.18) |> tanh_drive(2)")
    ks = Ressac.enumerate_knobs(g)
    names = [k.name for k in ks if k.kind === :node]
    @test :start in names && :end in names && :rq in names && :mul in names    # Line, RLPF, MulAdd du drive
    @test !(:param in names)                                                    # plus de slot inconnu
    groups = [gl for (gl, _) in Ressac.knob_groups(g, ks)]
    @test groups == ["global", "enveloppe", "filtre", "mix"]
    lines = Ressac.explain_genome(g)
    spans = Ressac._explain_spans(lines, 40)
    @test all(l -> sum(sp -> textwidth(sp.content), l; init = 0) <= 40, spans)   # replié, jamais rogné
    @test length(spans) > length(lines)
    title = findfirst(l -> !isempty(l) && l[1].content == "SYNTHÈSE", spans)
    @test title !== nothing && spans[title][1].style.bold
    arrow = findfirst(l -> !isempty(l) && startswith(l[1].content, "  ←"), spans)
    @test arrow !== nothing && any(sp -> sp.content == "[grain] ", spans[arrow])
end

@testset "aller-retour — un synth écrit à la main s'exporte en DSL et en SC valides" begin
    src = "@synth :h (freq=220) begin\n  a = saw(:freq) |> soft_clip() |> clip(-0.5, 0.5)\n" *
          "  a |> low_pass(midicps(60)) |> env_perc(0.01, 0.4)\nend"
    g = Ressac.genome_from_dsl(src)
    sc = Ressac.render_synthdef(g, :h)
    @test occursin(".softclip", sc) && occursin(".clip(-0.5, 0.5)", sc) && occursin("(60.0).midicps", sc)
    @test occursin("Env.perc(", sc) && !occursin("Softclip.ar", sc) && !occursin("Midicps.ar", sc) && !occursin("EnvPerc", sc)
    dsl = Ressac.render_dsl(g, :h)
    @test occursin("|> soft_clip()", dsl) && occursin("midicps(", dsl) && occursin("|> env_perc(0.01, 0.4", dsl)
    g2 = Ressac.genome_from_dsl(dsl)                        # l'export se relit…
    @test g2 !== nothing && Ressac.render_synthdef(g2, :h) == sc   # …et rend le même SC
    @test (Core.eval(Ressac.SynthDSL, Ressac.SynthDSL._dsl_parse_all(dsl)); true)   # …et s'évalue (T)
    # une constante dans une étape (export d'une mutation) s'évalue
    @test (Core.eval(Ressac.SynthDSL, Ressac.SynthDSL._dsl_parse_all("@synth :c (freq=220) begin\n n2 = 4.0 |> clip2(1.0)\n ugen(:LFPulse, n2, 0.0, 0.3; rate = :kr) * saw(:freq)\nend")); true)
    # les conversions et blocs opaques ne sont pas matière à mutation
    for role in (:source, :filter, :math, :mod)
        @test !any(s -> s.name in (:Raw, :Midicps, :Cpsmidi, :Div, :K2A, :DC, :Klang), Ressac.catalog_by_role(role))
    end
    @test Ressac.ugen_spec(:Midicps) !== nothing                # mais restent connus (knobs, explication)
end


@testset "export en pipes — le vocabulaire des wrappers, aller-retour exact" begin
    srcs = ["@synth :a (freq=220, sustain=0.5) saw(:freq) |> rlpf(line(3000, 500, :sustain), 0.18) |> tanh_drive(2)",
            "@synth :b (freq=220) begin\n  a = saw(:freq) + saw(:freq * 1.007)\n  a |> low_pass(lfo(0.2; low = 300, high = 2000)) |> env_perc(0.01, 0.4) |> stereo_pan(0.2)\nend",
            "@synth :c (freq=110) begin\n  x = pulse(:freq, 0.3) |> moog_ff(1200, 2)\n  (x |> comb_c(0.25, 2.0)) + x\nend",
            "@synth :f (freq=200) feedback() do fb\n  saw(:freq) + fb * 0.3 |> soft_clip()\nend"]
    for src in srcs
        g = Ressac.genome_from_dsl(src)
        @test g !== nothing
        dsl = Ressac.render_dsl(g, :x)
        @test !occursin("ugen(:Saw", dsl) && !occursin("ugen(:RLPF", dsl)      # le vocabulaire, pas la forme brute
        @test occursin("|> safe()", dsl)
        g2 = Ressac.genome_from_dsl(dsl)
        @test g2 !== nothing && Ressac.render_synthdef(g2, :x) == Ressac.render_synthdef(g, :x)
    end
    dsl = Ressac.render_dsl(Ressac.genome_from_dsl(srcs[1]), :a)
    # trois étapes ou plus : une par ligne
    @test occursin("    saw(:freq)\n        |> rlpf(line(3000.0, 500.0, :sustain), 0.18)\n        |> tanh_drive(2.0)\n        |> safe()", dsl)
    # deux étapes : sur une ligne
    @test occursin("saw(:freq) |> safe()", Ressac.render_dsl(Ressac.genome_from_dsl("@synth :d (freq=220) saw(:freq)"), :d))
    dsl = Ressac.render_dsl(Ressac.genome_from_dsl(srcs[2]), :b)
    @test occursin("|> env_perc(0.01, 0.4", dsl) && occursin("|> stereo_pan(0.2", dsl) && occursin("lfo(0.2)", dsl) || occursin("lfo(", dsl)
    @test occursin("n1 = ", dsl) || !occursin("n2 = ", dsl)                    # une variable seulement si partagé
    dsl = Ressac.render_dsl(Ressac.genome_from_dsl(srcs[3]), :c)
    @test occursin("n1 = pulse(:freq, 0.3) |> moog_ff(1200.0, 2.0)", dsl)        # x est lu deux fois : variable
    @test occursin("comb_c(0.25, 2.0", dsl)
end
