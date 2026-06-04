using Test
using Ressac

@testset "synth explainer — deterministic explanation" begin
    function _dark_filtered()
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        f = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                             Ressac.ConstArg(300.0), Ressac.ConstArg(0.2)])
        g.output_id = f
        return g
    end

    @testset "explains the signal chain + controls" begin
        lines = Ressac.explain_genome(_dark_filtered())
        whole = join(lines, "\n")
        @test occursin("CHAÎNE DE SIGNAL", whole)
        @test occursin("Saw", whole) && occursin("dent-de-scie", whole)
        @test occursin("RLPF", whole) && occursin("passe-bas", whole)
        @test occursin("CONTRÔLES", whole) && occursin("freq", whole)
        @test occursin("sustain", whole) && occursin("release", whole)
    end

    @testset "structural perception cues (low cutoff → dark, resonance)" begin
        whole = join(Ressac.explain_genome(_dark_filtered()), "\n")
        @test occursin("POURQUOI", whole)
        @test occursin("sombre", whole)              # coupure 300 Hz
        @test occursin("résonan", whole)             # rq 0.2
    end

    @testset "saturation + feedback cues" begin
        g = Ressac.Genome()
        saw = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        t   = Ressac.add_node!(g, :Tanh, :ar, Ressac.Arg[Ressac.NodeRef(saw)])
        fb  = Ressac.add_node!(g, :FbIn, :ar, Ressac.Arg[])
        mix = Ressac.add_node!(g, :Mix, :ar, Ressac.Arg[Ressac.NodeRef(t), Ressac.NodeRef(fb)])
        g.output_id = mix
        whole = join(Ressac.explain_genome(g), "\n")
        @test occursin("saturation", whole) || occursin("distorsion", whole)
        @test occursin("feedback", whole)
    end

    @testset "acoustic cues from measured descriptors" begin
        g = _dark_filtered()
        # descripteurs « basse » : centroïde bas, graves haut, tonal, tenu, pitch net
        descr = [0.1, 0.85, 0.05, 0.4, 0.8, 0.95]
        whole = join(Ressac.explain_genome(g; descriptors = descr), "\n")
        @test occursin("basse", whole) || occursin("grave", whole)
        @test occursin("sombre", whole)
        @test occursin("hauteur", whole)
    end

    @testset "exported synth carries its genome → explainable in :synth" begin
        g = _dark_filtered(); g.controls[:freq] = 90.0
        txt = Ressac.render_dsl(g, :mybass) * "\n" * Ressac.genome_comment(g) * "\n"
        @test occursin("ressac-genome:", txt)
        g2 = Ressac.genome_from_text(txt)
        @test g2 isa Ressac.Genome
        # même structure rendue → génome récupéré fidèlement
        @test Ressac.render_synthdef(g2, :x) == Ressac.render_synthdef(g, :x)
        # explain via fichier
        path = tempname() * ".jl"; write(path, txt)
        lines = Ressac.explain_synth_file(path)
        @test any(l -> occursin("RLPF", l), lines)
        @test any(l -> occursin("sombre", l), lines)
        rm(path; force = true)
    end

    @testset "synth without embedded genome → graceful note" begin
        path = tempname() * ".jl"
        write(path, "@synth :x SynthDSL.saw(:freq)\n")
        lines = Ressac.explain_synth_file(path)
        @test any(l -> occursin("pas de génome", l), lines)
        rm(path; force = true)
    end

    @testset "simple sound → no spurious cues" begin
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :SinOsc, :ar, Ressac.Arg[Ressac.ControlRef(:freq), Ressac.ConstArg(0.0)])
        g.output_id = s
        whole = join(Ressac.explain_genome(g), "\n")
        @test occursin("sinus", whole)
        @test occursin("POURQUOI", whole)            # section présente même si peu d'indices
    end
end
