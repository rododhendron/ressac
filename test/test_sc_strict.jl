include(joinpath(@__DIR__, "helpers.jl"))
import Random
# Le côté synthèse ne perd rien en silence — phase 3 de la roadmap.
#
# `:prune`, `:explain` et `:todsl` relisent le SC d'un synth, en font un
# génome, et réécrivent le synth à partir de lui. Tout ce que la relecture
# « devinait » (un 0 pour un inconnu, la première voie d'un tableau, la
# priorité des opérateurs) finissait donc dans le texte du joueur.

const _SS_CTL = Set([:freq, :sustain, :gain, :cutoff])
_ss(code; ctl = _SS_CTL) = Ressac.genome_from_sc(code, ctl)
_ss_reason(code; ctl = _SS_CTL) = last(Ressac.parse_sc_expr(code, ctl))
# Le SC que le génome rend pour sa sortie (sans la chaîne de sécurité).
_ss_sc(g) = Ressac._emit_node(g, g.output_id)
_ss_names(g) = sort!([String(n.ugen) for n in values(g.nodes)])
# Aller-retour par le DSL : le génome d'un texte, exporté, relu.
function _ss_roundtrip(text)
    g = Ressac.genome_from_dsl(text)
    g === nothing && return (nothing, nothing, nothing)
    out = Ressac.render_dsl(g, :rt)
    return (g, out, Ressac.genome_from_dsl(out))
end

@testset "synthèse — rien ne se perd en silence" begin

    @testset "S1 — ce qui ne se lit pas est refusé, avec sa raison" begin
        for (code, why) in (("SinOsc.ar(machin)", "identifiant inconnu « machin »"),
                            ("Saw.ar(freq) * amp", "identifiant inconnu « amp »"),
                            ("Saw.ar(freq) ) junk", "texte non lu"),
                            ("Saw.ar(freq) ! 2", "texte non lu"),
                            ("Saw.ar(freq", "« ) » attendu"),
                            ("RLPF.ar(Saw.ar(freq), machin: 3)", "argument nommé « machin: »"),
                            ("Saw.ar(freq) * ", "fin inattendue"),
                            ("Saw.ar(freq) § 2", "texte non lu"),
                            ("[Saw.ar(freq), ", "fin inattendue"),
                            ("{ Saw.ar(freq) ", "non fermé"),
                            ("(1 + 2) * 3", "pas un signal"))
            @test _ss(code) === nothing
            @test occursin(why, _ss_reason(code))
        end
        # Une vraie erreur de programmation n'est pas déguisée en « illisible ».
        @test_throws MethodError Ressac.parse_sc_expr(42, _SS_CTL)
    end

    @testset "S1 — commentaires, arguments nommés, tableaux, littéraux" begin
        @test _ss_sc(_ss("Saw.ar(freq) /* x */ * 0.5 // fin")) == "((Saw.ar(freq) * 0.5) + 0.0)"
        # `mul:` et `add:` sont le `* mul + add` qu'ils sont.
        @test _ss_sc(_ss("SinOsc.ar(freq, mul: 0.1)")) == "((SinOsc.ar(freq) * 0.1) + 0.0)"
        @test _ss_sc(_ss("SinOsc.ar(freq, 0, 0.1, 0.5)")) == "SinOsc.ar(freq, 0.0, 0.1, 0.5)"
        @test _ss_sc(_ss("SinOsc.ar(freq, add: 0.5, mul: 0.1)")) == "((SinOsc.ar(freq) * 0.1) + 0.5)"
        # Un mot-clé que le catalogue sait placer prend sa place.
        @test _ss_sc(_ss("RLPF.ar(Saw.ar(freq), rq: 0.2, freq: 900)")) == "RLPF.ar(Saw.ar(freq), 900.0, 0.2)"
        @test _ss_sc(_ss("RLPF.ar(Saw.ar(freq), rq: 0.2)")) == "RLPF.ar(Saw.ar(freq), 1200.0, 0.2)"
        @test _ss("RLPF.ar(Saw.ar(freq), 800, freq: 900)") === nothing        # donné deux fois
        @test _ss_sc(_ss("(Saw.ar(freq) * EnvGen.kr(Env.perc(0.01, 0.4), doneAction: 2))")) ==
              "((Saw.ar(freq) * EnvGen.kr(Env.perc(0.01, 0.4), 1.0, 1.0, 0.0, 1.0, 2.0)) + 0.0)"   # doneAction gardé
        # Un tableau garde toutes ses voies.
        g = _ss("Saw.ar([freq, freq * 1.01])")
        @test _ss_sc(g) == "Saw.ar([freq, ((freq * 1.01) + 0.0)])"
        @test "Chan" in _ss_names(g)
        @test _ss_sc(_ss("Saw.ar([freq])")) == "Saw.ar([freq])"
        # `Mix.ar([a, b, c])` est la somme de ses voies.
        @test _ss_sc(_ss("Mix.ar([Saw.ar(freq), Pulse.ar(freq), WhiteNoise.ar])")) ==
              "((Saw.ar(freq) + Pulse.ar(freq)) + WhiteNoise.ar())"
        @test _ss_sc(_ss("Mix([SinOsc.ar(freq), Saw.ar(freq)])")) == "(SinOsc.ar(freq) + Saw.ar(freq))"
        # Symboles, nil, références : gardés tels quels.
        @test _ss_sc(_ss("Env.linen(0.01, sustain, 0.1, 1, \\sin)")) == "Env.linen(0.01, sustain, 0.1, 1.0, \\sin)"
        @test _ss_sc(_ss("Klang.ar(`[[220, 440], nil, nil])")) == "Klang.ar(`[[220.0, 440.0], nil, nil])"
        @test _ss_sc(_ss("SinOsc.ar(freq, inf)")) == "SinOsc.ar(freq, inf)"
    end

    @testset "S3 — les opérateurs de gauche à droite, comme SC" begin
        # `a + b * c` est `(a + b) * c` en SuperCollider.
        @test _ss_sc(_ss("SinOsc.ar(freq) + Saw.ar(freq) * 0.5")) == "(((SinOsc.ar(freq) + Saw.ar(freq)) * 0.5) + 0.0)"
        @test _ss_sc(_ss("Saw.ar(freq + 10 * 2)")) == "Saw.ar((((freq + 10.0) * 2.0) + 0.0))"
        @test _ss_sc(_ss("Saw.ar(freq) - 0.5 * 2")) == "(((Saw.ar(freq) + -0.5) * 2.0) + 0.0)"
        # Entre constantes aussi : 1 + 2 * 3 vaut 9.
        @test _ss_sc(_ss("Saw.ar(1 + 2 * 3)")) == "Saw.ar(9.0)"
        # Parenthésé, rien ne change — et c'est ce que tous les rendus écrivent.
        @test _ss_sc(_ss("(SinOsc.ar(freq) + (Saw.ar(freq) * 0.5))")) == "(SinOsc.ar(freq) + ((Saw.ar(freq) * 0.5) + 0.0))"
        # Autres opérateurs binaires.
        @test _ss_sc(_ss("SinOsc.ar(freq) ** 3")) == "(SinOsc.ar(freq) ** 3.0)"
        @test _ss_sc(_ss("Saw.ar(freq) > 0")) == "(Saw.ar(freq) > 0.0)"
        @test _ss_sc(_ss("Saw.ar(freq * 2 ** 3)")) == "Saw.ar(((freq * 2.0) + 0.0) ** 3.0)" ||
              _ss_sc(_ss("Saw.ar(freq * 2 ** 3)")) == "Saw.ar((((freq * 2.0) + 0.0) ** 3.0))"
    end

    @testset "S4 — chorus et phaser écrivent ce qu'ils veulent dire" begin
        S = Ressac.SynthDSL
        dry = S.chorus(S.saw(:freq), 0.5, 0.002, 0.0).code
        @test dry == "((Saw.ar(freq) * (1 - 0.0)) + (DelayL.ar(Saw.ar(freq), 0.05, (0.01 + SinOsc.kr(0.5).range(0, 0.002))) * 0.0))"
        # Relu de gauche à droite : le signal sec plus le signal traité × mix.
        g = _ss(S.chorus(S.saw(:freq), 0.5, 0.002, 0.3).code)
        out = g.nodes[g.output_id]
        @test out.ugen === :MulAdd && out.args[2] == Ressac.ConstArg(0.7)       # sec × (1 − mix)
        wet = g.nodes[out.args[3].id]
        @test wet.ugen === :MulAdd && wet.args[2] == Ressac.ConstArg(0.3) && g.nodes[wet.args[1].id].ugen === :DelayL
        # Phaser : quatre étages lisibles, LFO à 0.3 × 1.0, 1.1, 1.2, 1.3.
        g = _ss(S.phaser(S.saw(:freq), 0.3, 800).code)
        @test count(==("AllpassC"), _ss_names(g)) == 4
        rates = sort!([n.args[1].value for n in values(g.nodes) if n.ugen === :SinOscKR])
        @test rates ≈ [0.3, 0.33, 0.36, 0.39]
        @test !occursin("inject", S.phaser(S.saw(:freq)).code)
    end

    @testset "S5 — une méthode ou un opérateur sans fiche reste du SC valide" begin
        S = Ressac.SynthDSL
        for (dsl, sc) in (("saw(:freq) |> abs_sig()", "(Saw.ar(freq)).abs"),
                          ("saw(:freq) |> sqrt_sig()", "(Saw.ar(freq)).sqrt"),
                          ("saw(:freq) |> pow_sig(3)", "(Saw.ar(freq)).pow(3.0)"),
                          ("-saw(:freq)", "((Saw.ar(freq) * -1.0) + 0.0)"),
                          ("(sin_osc(:freq) ^ 3) |> rlpf(800, 0.3)", "RLPF.ar((SinOsc.ar(freq, 0.0) ** 3.0), 800.0, 0.3)"),
                          ("saw(:freq) |> ugen(Symbol(\".distort\"))", "(Saw.ar(freq)).distort"),
                          ("saw(:freq) |> ugen(Symbol(\".lag\"), 0.1)", "(Saw.ar(freq)).lag(0.1)"),
                          ("saw(:freq) * ugen(Symbol(\"Env.triangle\"), 1, 1)", "((Saw.ar(freq) * Env.triangle(1.0, 1.0)) + 0.0)"))
            (g, out, g2) = _ss_roundtrip("@synth :rt (freq=220, sustain=0.5) $dsl")
            @test g !== nothing
            g === nothing && continue
            @test _ss_sc(g) == sc
            @test !occursin(r"\b(Abs|Neg|Sqrt|Pow|Distort|Lag)\.ar\(", _ss_sc(g))    # jamais une classe inventée
            @test g2 !== nothing && _ss_sc(g2) == sc                                 # l'export se relit à l'identique
        end
    end

    @testset "S6 — arité : pas de BoundsError, pas d'argument perdu" begin
        g = _ss("Saw.ar(freq) * LFPulse.kr(2)")
        @test Ressac.render_synthdef(g, :x) isa String
        @test occursin("LFPulse.kr(2.0)", _ss_sc(g))
        @test occursin("SinOsc.kr(2.0, 1.5)", _ss_sc(_ss("Saw.ar(freq) * SinOsc.kr(2, 1.5)")))
        (g, out, g2) = _ss_roundtrip("@synth :rt (freq=220) saw(:freq) * ugen(:SinOsc, 2, 1.5; rate = :kr)")
        @test g2 !== nothing && occursin("SinOsc.kr(2.0, 1.5)", _ss_sc(g2))
        # Rendre n'importe quel génome lu ne lève jamais.
        for code in ("Saw.ar", "RLPF.ar(Saw.ar(freq))", "Pan2.ar(Saw.ar(freq))", "EnvGen.kr(Env.perc)", "(Saw.ar(freq)).fold2")
            g = _ss(code)
            @test g !== nothing && Ressac.render_synthdef(g, :x) isa String && Ressac.render_dsl(g, :x) isa String
        end
    end

    @testset "S7 — .range d'un UGen unipolaire" begin
        # LFPulse va de 0 à 1 : .range(lo, hi) = x * (hi − lo) + lo.
        @test _ss_sc(_ss("Saw.ar(freq) * LFPulse.kr(4, 0, 0.5).range(0, 1)")) == "((Saw.ar(freq) * LFPulse.kr(4.0, 0.0, 0.5)) + 0.0)"
        @test occursin("((LFPulse.kr(4.0, 0.0, 0.5) * 600.0) + 200.0)", _ss_sc(_ss("LPF.ar(Saw.ar(freq), LFPulse.kr(4, 0, 0.5).range(200, 800))")))
        # Un bipolaire garde la formule (hi − lo)/2, (hi + lo)/2.
        @test occursin("((SinOsc.kr(0.2) * 250.0) + 550.0)", _ss_sc(_ss("LPF.ar(Saw.ar(freq), SinOsc.kr(0.2).range(300, 800))")))
        # La porte du DSL reste une porte après export.
        (g, out, g2) = _ss_roundtrip("@synth :rt (freq=220) saw(:freq) * lfo_pulse(4)")
        @test g2 !== nothing && !occursin("* 0.5", out) && occursin("LFPulse", out)
        # Bornes calculées, unipolaire : x * (hi − lo) + lo, en nœuds.
        g = _ss("LPF.ar(Saw.ar(freq), Impulse.kr(2).range(cutoff, cutoff + 500))")
        @test g !== nothing && occursin("Impulse.kr(2.0)", _ss_sc(g))
    end

    @testset "S2 — `var x = expr;` dans un SynthDef écrit à la main" begin
        src = "SynthDef(\\foo, { |out=0, freq=440, amp=0.1| var sig = Saw.ar(freq), unused; " *
              "sig = RLPF.ar(sig, 800, 0.3); Out.ar(out, sig * amp); })"
        (name, args, expr) = Ressac.parse_synthdef(src)
        @test name === :foo && args[:amp] == 0.1
        @test occursin("Saw.ar(freq)", expr)
        (nm, dsl) = Ressac.synthdef_to_dsl(src)
        @test occursin("saw(:freq)", dsl) && occursin("rlpf(800.0, 0.3)", dsl) && occursin(":amp", dsl)
        @test !occursin("DC", dsl)
        # Le SynthDef que Ressac rend lui-même se relit.
        g = Ressac.genome_from_dsl("@synth :rt (freq=220) begin\n n = white()\n (n + (n |> low_pass(800))) |> safe()\nend")
        back = Ressac.synthdef_to_dsl(Ressac.render_synthdef(g, :rt))
        @test back !== nothing && occursin("white()", back[2]) && occursin("low_pass(800.0)", back[2])
    end

    @testset "S12 — un nœud partagé : audition et export disent la même chose" begin
        # Dans le DSL, `n = white()` lu deux fois écrit deux bruits (une
        # variable Julia recopie son expression). Le rendu SC d'un génome
        # dont un nœud est lu deux fois fait de même : ce qu'on auditionne
        # est ce qu'on exporte.
        g = Ressac.Genome()
        n = Ressac.add_node!(g, :WhiteNoise, :ar, Ressac.Arg[])
        inv = Ressac.add_node!(g, :MulAdd, :ar, Ressac.Arg[Ressac.NodeRef(n), Ressac.ConstArg(-1.0), Ressac.ConstArg(0.0)])
        g.output_id = Ressac.add_node!(g, :Mix, :ar, Ressac.Arg[Ressac.NodeRef(n), Ressac.NodeRef(inv)])
        heard = Ressac.render_synthdef(g, :rt)
        @test count("WhiteNoise.ar", heard) == 2
        dsl = Ressac.render_dsl(g, :rt)
        @test occursin("n1 = white()", dsl)
        cap = Any[]; Ressac._DRONE_CAPTURE[] = cap
        try
            Core.eval(Ressac.SynthDSL, Ressac.SynthDSL._dsl_parse_all(dsl))
        finally
            Ressac._DRONE_CAPTURE[] = nothing
        end
        @test count("WhiteNoise.ar", cap[end][2]) == 2          # le DSL exporté compile aussi deux bruits
        # …et il se relit en un génome qui rend le même SC.
        @test Ressac.render_synthdef(Ressac.genome_from_dsl(dsl), :rt) == heard
    end

    @testset "multicanal — gardé à l'export, ramené à une voie à l'audition" begin
        (g, out, g2) = _ss_roundtrip("@synth :rt (freq=220) saw(chan(:freq, :freq * 1.01)) |> low_pass(900)")
        @test occursin("chan(:freq, :freq * 1.01)", out)
        @test g2 !== nothing && _ss_sc(g2) == _ss_sc(g)
        @test occursin(".asArray.mean", Ressac.render_synthdef(g, :rt))
        @test !occursin("asArray", Ressac.render_synthdef(_ss("Saw.ar(freq)"), :x))
        (g, out, g2) = _ss_roundtrip("@synth :rt (freq=220) klang([220, 440, 660], [0.3, 0.2, 0.1])")
        @test occursin("klang([220.0, 440.0, 660.0], [0.3, 0.2, 0.1])", out)
        @test g2 !== nothing && occursin("Klang.ar(`[[220.0, 440.0, 660.0], [0.3, 0.2, 0.1], nil])", _ss_sc(g2))
    end

    @testset "S10 — les nombres s'écrivent en SC par un seul chemin" begin
        S = Ressac.SynthDSL
        @test S.sc_num(1 // 3) == string(1 / 3) && !occursin("//", S.saw(1 // 3).code)
        @test S.sin_osc(:freq, pi).code == "SinOsc.ar(freq, $(Float64(pi)))"
        @test S.line(0, Inf, 1).code == "Line.kr(0, inf, 1)" || occursin("inf", S.line(0, Inf, 1).code)
        @test (S.saw(:freq) * (1 // 3)).code == "(Saw.ar(freq) * $(1 / 3))"
        @test (:freq * (1 // 2)).code == "(freq * 0.5)"
        @test_throws ArgumentError S.sc_num(NaN)
        @test S.sc_num(-Inf) == "-inf" && S.sc_num(3) == "3" && S.sc_num(2.5f0) == "2.5"
        # Une courbe d'enveloppe numérique, ou nommée.
        @test occursin("Env.linen(0.01, 1, 0.1, 1, -4.0)", S.env_linen(S.saw(:freq), 0.01, 1, 0.1; curve = -4.0).code)
        @test occursin("\\sin", S.env_linen(S.saw(:freq), 0.01, 1, 0.1; curve = :sin).code)
        (g, out, g2) = _ss_roundtrip("@synth :rt (freq=220) saw(:freq) |> env_linen(0.01, 1, 0.1; curve = :sin)")
        @test occursin("curve = :sin", out) && g2 !== nothing && _ss_sc(g2) == _ss_sc(g)
        (g, out, g2) = _ss_roundtrip("@synth :rt (freq=220) saw(:freq) |> env_linen(0.01, 1, 0.1; curve = -3.0)")
        @test occursin("curve = -3.0", out) && g2 !== nothing
        (g, out, g2) = _ss_roundtrip("@synth :rt (freq=220) saw(:freq) |> env_linen(0.01, 1, 0.1)")
        @test !occursin("curve", out)
        # Constantes du génome.
        @test Ressac._fmt_const(1.0e20) == "1.0e20" && Ressac._fmt_const(Inf) == "inf" && Ressac._fmt_const(2.0) == "2.0"
        @test Ressac._fmt_const(NaN) == "0.0" && Ressac._fmt_const(Inf; inf = "Inf") == "Inf"
        @test Ressac.render_synthdef(_ss("Saw.ar(freq) * 1e20"), :x) isa String
    end

    @testset "S11 — un nom de synth est un identifiant" begin
        S = Ressac.SynthDSL
        @test S.valid_synth_name("acid_2") && S.valid_synth_name(:Wob)
        @test !S.valid_synth_name("my-synth") && !S.valid_synth_name("303") && !S.valid_synth_name("") && !S.valid_synth_name("a b")
        g = _ss("Saw.ar(freq)")
        for bad in (Symbol("my-synth"), Symbol("303"))
            @test_throws ArgumentError Ressac.render_dsl(g, bad)
            @test_throws ArgumentError Ressac.render_synthdef(g, bad)
            @test_throws ArgumentError S.build_synth(bad, S.saw(:freq))
        end
        # À la saisie dans l'explorateur : le tiret et le chiffre en tête ne s'écrivent pas.
        p = Ressac._pane_new(:explorer, Dict{String,Any}())
        p.naming = :synth
        for c in "3my-synth_2"; Ressac._explorer_naming_key!(p, Tachikoma.KeyEvent(c)); end
        @test p.name_buf == "mysynth_2"
    end

    @testset "S9 — un EnvGen modulateur ne dispense pas de libérer la note" begin
        S = Ressac.SynthDSL
        frees(src) = occursin(r"doneAction:\s*2", src)
        # Enveloppe sur le filtre, done_action = 0 : l'enveloppe automatique reste.
        sig = S.rlpf(S.saw(:freq), S.env_gen(2000, S.env([0, 1, 0], [0.1, 0.2]); done_action = 0), 0.3)
        src = S.build_synth(:x, sig)
        @test frees(src) && occursin("Env.linen(0.01, sustain, 0.1)", src)
        # Une enveloppe d'amplitude qui libère : pas de seconde enveloppe.
        src = S.build_synth(:x, S.env_perc(S.saw(:freq), 0.01, 0.4))
        @test count("EnvGen", src) == 1 && frees(src)
        # auto_env = false : le joueur a choisi, rien n'est ajouté.
        @test !occursin("EnvGen", S.build_synth(:x, S.saw(:freq); auto_env = false))
        @test !S._frees_itself("EnvGen.kr(e, doneAction: 0)") && !S._frees_itself("EnvGen.kr(e, doneAction: 1)")
        @test S._frees_itself("EnvGen.kr(e, doneAction:2)") && S._frees_itself("x * EnvGen.kr(e, doneAction: 14)")
    end

    @testset "S8 — la mutation sur un génome lu dans un texte" begin
        rng = Random.MersenneTwister(7)
        # Un UGen hors catalogue ne fait plus lever les opérateurs.
        g0 = _ss("Pluck.ar(WhiteNoise.ar, 1, 0.2, 0.01) * 0.5")
        @test g0 !== nothing
        for _ in 1:200
            g = Ressac.mutate(g0, rng; radius = 0.8)
            @test Ressac.render_synthdef(g, :x) isa String
        end
        for op in (Ressac.op_perturb_const!, Ressac.op_change_rate!, Ressac.op_remove_node!, Ressac.op_swap_ugen!,
                   Ressac.op_insert_node!, Ressac.op_rewire!, Ressac.op_graft_mod!, Ressac.op_add_feedback!,
                   Ressac.op_duplicate_subgraph!)
            for _ in 1:50
                g = Ressac._copy_genome(_ss("Pluck.ar([WhiteNoise.ar, Saw.ar(freq)], 1, 0.2, 0.01).abs ** 2"))
                op(g, rng); Ressac.repair!(g)
                @test Ressac.render_synthdef(g, :x) isa String
            end
        end
        # Une valeur hors plage du catalogue est perturbée autour d'elle-même, pas écrasée.
        base = _ss("RLPF.ar(Saw.ar(freq), SinOsc.kr(0.2).range(300, 800), 0.3)")
        for _ in 1:300
            g = Ressac._copy_genome(base)
            Ressac.op_perturb_const!(g, rng; radius = 0.1)
            m = only(n for n in values(g.nodes) if n.ugen === :MulAdd)
            @test 150 < m.args[2].value < 400 && 350 < m.args[3].value < 800
        end
        g = Ressac._copy_genome(_ss("Saw.ar(freq) * -1"))
        for _ in 1:100; Ressac.op_perturb_const!(g, rng; radius = 0.5); end
        @test only(n for n in values(g.nodes) if n.ugen === :MulAdd).args[2].value < 0      # l'inversion reste une inversion
        # Insérer un nœud ne jette pas le signal : il entre par l'entrée audio.
        med = Ressac.ugen_spec(:Median)
        @test Ressac._input_slot(med) == 2
        g = Ressac.Genome(); src = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        id = Ressac._new_node_from_spec!(g, med, Ressac.NodeRef(src))
        @test g.nodes[id].args == Ressac.Arg[Ressac.ConstArg(3.0), Ressac.NodeRef(src)]
        # Changer d'UGen remappe par nom puis par nature, et ramène dans la plage.
        args = Ressac._remap_args(Ressac.ugen_spec(:Saw), Ressac.ugen_spec(:Logistic), Ressac.Arg[Ressac.ConstArg(220.0)])
        @test args == Ressac.Arg[Ressac.ConstArg(3.7), Ressac.ConstArg(220.0)]            # chaos au défaut, freq reprise
        args = Ressac._remap_args(Ressac.ugen_spec(:RLPF), Ressac.ugen_spec(:BPF),
                                  Ressac.Arg[Ressac.NodeRef(1), Ressac.ConstArg(900.0), Ressac.ConstArg(0.07)])
        @test args == Ressac.Arg[Ressac.NodeRef(1), Ressac.ConstArg(900.0), Ressac.ConstArg(0.1)]   # rq ramené à sa borne
    end

    @testset "S14 — le son tenu part à la hauteur et la durée demandées" begin
        st = Ressac.AuditionState(3)
        osc = MockOSCClient()
        Ressac.audition_hold!(st, osc, _ss("Saw.ar(freq)"), 110.0, 8.0)
        msg = Ressac.decode_message(osc.sent[end])
        @test msg.address == "/ressac/evalAndPlay"
        kv = Dict(String(msg.args[i]) => msg.args[i + 1] for i in 3:2:(length(msg.args) - 1))
        @test kv["freq"] == 110.0f0 && kv["sustain"] == 8.0f0
    end

    @testset "S15 — :export d'un synth DSL passe par le chemin de T" begin
        oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]
        Ressac._WAVE_RENDER[] = g -> (Float32[0.0f0, 0.1f0, 0.0f0], 44100); Ressac._WAVE_SYNC[] = true
        app, frame = _new_app()
        Ressac._active_editor(app).mode = :normal
        Ressac._LIVE_SCHEDULER[] = app.scheduler
        try
            _exec_ex_command!(app, "synth expdsl")
            Tachikoma.view(app, frame)
            snd = Ressac._current_sound(app)
            @test snd !== nothing && snd.name == "expdsl"
            @test Ressac._sound_write!(snd, "@synth :expdsl (freq=220, sustain=0.2) saw(:freq) |> low_pass(900)")
            empty!(app.scheduler.osc.sent)
            Ressac._export_current_synth!(app; duration = 0.02, pre_roll = 0.0)
            @test app.recording
            @test timedwait(() -> !app.recording, 10.0) === :ok
            sent = [Ressac.decode_message(b) for b in app.scheduler.osc.sent]
            addrs = [m.address for m in sent]
            @test addrs[1] == "/ressac/recStart" && addrs[end] == "/ressac/recStop"
            play = only(m for m in sent if m.address == "/ressac/evalAndPlay")
            # Du SuperCollider compilé, pas le texte Julia du bloc — et le son seul, pas les patterns autour.
            @test occursin("SynthDef(\\expdsl", String(play.args[2])) && occursin("LPF.ar(Saw.ar(freq), 900)", String(play.args[2]))
            @test !occursin("@synth", String(play.args[2])) && !occursin("@d1", String(play.args[2]))
            @test endswith(String(sent[1].args[1]), ".wav") && startswith(String(sent[1].args[1]), pwd())
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            Ressac._WAVE_RENDER[] = oldr; Ressac._WAVE_SYNC[] = olds
        end
    end

    @testset "le joueur lit pourquoi un synth n'est pas relu" begin
        (g, why) = Ressac.parse_dsl_synth("@synth :x (freq=220) saw(:freq) * SynthDSL.Sig(\"amp\")")
        @test g === nothing && occursin("identifiant inconnu « amp »", why)
        @test occursin("pas de `@synth`", last(Ressac.parse_dsl_synth("x = 1")))
        @test occursin("ne s'évalue pas", last(Ressac.parse_dsl_synth("@synth :x (freq=220) nexistepas(:freq)")))
        (r, why) = Ressac.synthdef_to_dsl_reason("SynthDef(\\foo, { |out=0, freq=440| Out.ar(out, Saw.ar(freq) * amp); })")
        @test r === nothing && occursin("identifiant inconnu « amp »", why)
        @test occursin("reconnaissable", last(Ressac.synthdef_to_dsl_reason("pas du SC")))
        # Dans l'app : :prune ne touche pas au texte et dit pourquoi ; :todsl renvoie à :synth <nom>.
        oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]
        Ressac._WAVE_RENDER[] = g -> (Float32[0.0f0, 0.1f0, 0.0f0], 44100); Ressac._WAVE_SYNC[] = true
        app, frame = _new_app()
        Ressac._active_editor(app).mode = :normal
        try
            _exec_ex_command!(app, "synth pourquoi")
            Tachikoma.view(app, frame)
            snd = Ressac._current_sound(app)
            @test snd !== nothing && snd.name == "pourquoi"
            ed = snd.code_editor
            text = "@synth :pourquoi (freq=220) saw(:freq) * SynthDSL.Sig(\"amp\")"
            @test Ressac._sound_write!(snd, text)
            whole = Tachikoma.text(ed)
            logs = _cmd_logs(app, "prune")
            @test any(l -> occursin(":prune — le buffer ne se relit pas en entier", l) && occursin("« amp »", l), logs)
            @test Ressac._sound_text(Ressac._current_sound(app)) == text && Tachikoma.text(ed) == whole
            logs = _cmd_logs(app, "todsl")
            @test any(l -> occursin(":todsl", l) && occursin(":synth <nom>", l), logs)
            @test Tachikoma.text(ed) == whole
        finally
            Ressac._WAVE_RENDER[] = oldr; Ressac._WAVE_SYNC[] = olds
        end
    end

end

# ── Ce que la conversion des .scd perdait (mesures E0.4) ─────────────

@testset "conversion SC → DSL — fonctions, enveloppes, délais" begin
    ctl = Set([:freq, :sustain, :gain, :sweep])
    names(g) = sort!([String(n.ugen) for n in values(g.nodes)])

    @testset "Array.fill(n, { |i| … }) est déroulé, pas remplacé par du silence" begin
        (g, why) = Ressac.parse_sc_expr("Mix.ar(Array.fill(3, { |i| Saw.ar(freq * (1 + (i * 0.01))) })) * 0.2", ctl)
        @test g !== nothing && count(==("Saw"), names(g)) == 3 && !("Silent" in names(g))
        dsl = Ressac.render_dsl(g, :x)
        @test occursin("saw(:freq)", dsl) && occursin("saw(:freq * 1.01)", dsl) && occursin("saw(:freq * 1.02)", dsl)
        # .dup(n) et .value de même ; les `var` du corps sont résolus.
        (g, _) = Ressac.parse_sc_expr("{ var f = freq * 2; SinOsc.ar(f) }.dup(2)", ctl)
        @test g !== nothing && count(==("SinOsc"), names(g)) >= 1
        (g, _) = Ressac.parse_sc_expr("{ WhiteNoise.ar }.value * 0.1", ctl)
        @test g !== nothing && "WhiteNoise" in names(g)
    end

    @testset "une fonction qu'on ne sait pas appeler fait refuser, avec la raison" begin
        (g, why) = Ressac.parse_sc_expr("SinOsc.ar(freq).collect({ |x| x * 2 })", ctl)
        @test g === nothing
        (g, why) = Ressac.parse_sc_expr("Saw.ar(freq) * { LFNoise1.kr(1) }", ctl)
        @test g === nothing && occursin("fonction { … }", why)
        (g, why) = Ressac.parse_sc_expr("Array.fill(freq, { Saw.ar(100) })", ctl)
        @test g === nothing && occursin("nombre de voies", why)
    end

    @testset "doneAction: 2 sur une enveloppe libre : elle libère la note, une seule fois" begin
        src = "Saw.ar(freq) * EnvGen.kr(Env([0, 1, 0], [0.1, sustain], \\sin), doneAction: 2)"
        (g, _) = Ressac.parse_sc_expr(src, ctl)
        dsl = Ressac.render_dsl(g, :x)
        @test occursin("env_pairs(", dsl) && occursin("curve = :sin", dsl)
        @test !occursin("env_linen", dsl)                          # pas de seconde enveloppe par-dessus
        sc = Core.eval(Ressac.SynthDSL, Ressac.SynthDSL._dsl_parse_all(dsl))
        @test count("doneAction: 2", sc) == 1
        # Sans doneAction, c'est une modulation : elle reste un EnvGen et ne coupe rien.
        (g, _) = Ressac.parse_sc_expr("RLPF.ar(Saw.ar(freq), EnvGen.kr(Env([400, 4000, 400], [1, 1])), 0.4)", ctl)
        @test !occursin("env_pairs", Ressac.render_dsl(g, :x))
    end

    @testset "un délai laisse passer l'audio : pas de DC devant le filtre qui suit" begin
        (g, _) = Ressac.parse_sc_expr("LPF.ar(CombL.ar(WhiteNoise.ar, 0.05, 1 / freq, sustain), 2000)", ctl)
        dsl = Ressac.render_dsl(g, :x)
        @test !occursin(":DC", dsl) && occursin("comb_l(", dsl) && occursin("low_pass(", dsl)
    end

    @testset "sin_osc(:freq), pas sin_osc(:freq, 0.0) — et l'aller-retour est stable" begin
        (g, _) = Ressac.parse_sc_expr("SinOsc.ar(freq, 0) * 0.3", ctl)
        dsl = Ressac.render_dsl(g, :x)
        @test occursin("sin_osc(:freq)", dsl)
        # Le SC compilé explicite la phase ; relu puis réécrit, le DSL ne bouge plus.
        compile(t) = Core.eval(Ressac.SynthDSL, Ressac.SynthDSL._dsl_parse_all(t))
        (once, _) = Ressac.synthdef_to_dsl_reason(compile(dsl))
        (twice, _) = Ressac.synthdef_to_dsl_reason(compile(once[2]))
        @test occursin("sin_osc(:freq)", once[2]) && once[2] == twice[2]
    end
end

@testset "tout son s'édite en DSL" begin
    sc = "SynthDef(\\vieux, { |out, freq = 220, sustain = 0.5, gain = 0.5|\n" *
         "    var sig = Saw.ar(freq) * EnvGen.kr(Env.perc(0.01, sustain), doneAction: 2);\n" *
         "    OffsetOut.ar(out, sig * gain);\n}).add;\n"

    @testset "as_dsl : un @synth passe, un SynthDef est converti, l'illisible est refusé" begin
        @test Ressac.as_dsl("@synth :a (freq=220) saw(:freq)") == ("@synth :a (freq=220) saw(:freq)", "")
        (dsl, why) = Ressac.as_dsl(sc)
        @test dsl !== nothing && occursin("@synth :vieux", dsl) && occursin("env_perc(", dsl)
        (dsl, why) = Ressac.as_dsl(replace(sc, "Saw.ar(freq)" => "Saw.ar(inconnu)"))
        @test dsl === nothing && occursin("inconnu", why)
        @test Ressac._is_raw_synthdef("// rien\nSynthDef(\\a, {})")
        @test !Ressac._is_raw_synthdef("// SynthDef(\\a, …) en commentaire SC")
    end

    @testset "un .scd laissé dans user-synths arrive converti dans le texte, :save le range en .jl" begin
        app, frame = _new_app()
        Ressac._active_editor(app).mode = :normal
        dir = joinpath(pwd(), "plugins", "user-synths"); mkpath(dir)
        write(joinpath(dir, "vieux.scd"), sc)
        _exec_ex_command!(app, "synth vieux")
        snd = Ressac._current_sound(app)
        @test snd !== nothing && snd.name == "vieux"
        ed = snd.code_editor
        @test startswith(Ressac._sound_text(snd), "@synth :vieux") && occursin("env_perc(", Ressac._sound_text(snd))
        @test !occursin("SynthDef(", Tachikoma.text(ed))
        # :w écrit la session, pas le son ; :save le range.
        _exec_ex_command!(app, "w sessvieux")
        @test !isfile(joinpath(dir, "vieux.jl"))
        _exec_ex_command!(app, "save")
        @test isfile(joinpath(dir, "vieux.jl")) && isfile(joinpath(dir, "vieux.scd"))   # l'archive n'est pas touchée
        @test read(joinpath(dir, "vieux.jl"), String) == Ressac._sound_text(snd) * "\n"
        # La librairie ne liste plus que le .jl.
        @test count(e -> e.name == "vieux", Ressac._synthlib_all_entries()) == 1
        @test only(e for e in Ressac._synthlib_all_entries() if e.name == "vieux").mode === :dsl
        # Un .scd illisible : on le dit, rien ne s'écrit à moitié.
        write(joinpath(dir, "casse.scd"), replace(sc, "vieux" => "casse", "Saw.ar(freq)" => "Saw.ar(inconnu)"))
        whole = Tachikoma.text(ed)
        logs = _cmd_logs(app, "synth casse")
        @test any(l -> occursin("ne se convertit pas en entier", l) && occursin("inconnu", l), logs)
        @test Tachikoma.text(ed) == whole && Ressac._current_sound(app).name == "vieux"
    end
end

@testset "les nombres exportés : trois décimales, notation scientifique au besoin" begin
    f = Ressac._fmt_const
    @test f(408.1107981565365) == "408.111"
    @test f(220.0) == "220.0" && f(0.5) == "0.5" && f(0.18) == "0.18"
    @test f(0.008) == "0.008"                          # trois décimales suffisent à le dire
    @test f(0.00507499) == "5.075e-3"                  # sinon la notation scientifique
    @test f(0.0015) == "1.5e-3"                        # jamais arrondi à 0.002
    @test f(-0.0004321) == "-4.321e-4"
    @test f(1.0e-5) == "1.0e-5"
    @test f(Inf) == "inf" && f(NaN) == "0.0"
    # Ce qui est écrit se relit au même nombre, à 1 % près.
    for v in (408.1107981565365, 0.00507499, 0.0015, 7.778780781446e-3, 123456.789, -0.0004321)
        @test isapprox(parse(Float64, f(v)), v; rtol = 0.01)
    end
    # Un export de l'explorateur n'a plus de queue de décimales.
    (g, _) = Ressac.parse_sc_expr("RLPF.ar(Saw.ar(freq), 200.0000000000007, 0.175000000000002)", Set([:freq]))
    dsl = Ressac.render_dsl(g, :x)
    @test occursin("rlpf(200.0, 0.175)", dsl)
end
