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

    @testset "functional, output-first structure" begin
        lines = Ressac.explain_genome(_dark_filtered())
        whole = join(lines, "\n")
        @test occursin("SYNTHÈSE", whole)
        @test occursin("EN SORTIE", whole)
        @test occursin("À LA BASE", whole)
        # le dernier geste (RLPF) est décrit en sortie ; la matière (Saw) à la base
        @test occursin("RLPF", whole) && occursin("passe-bas", whole)
        @test occursin("Saw", whole) && occursin("dent-de-scie", whole)
        @test occursin("freq", whole) && occursin("sustain", whole)
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

    @testset "genome_from_dsl round-trips our exported DSL" begin
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        f = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                             Ressac.ConstArg(800.0), Ressac.ConstArg(0.3)])
        g.output_id = f; g.controls[:freq] = 120.0
        g2 = Ressac.genome_from_dsl(Ressac.render_dsl(g, :foo))
        @test g2 isa Ressac.Genome
        @test Ressac.control(g2, :freq) == 120.0
        names = Set(n.ugen for n in values(g2.nodes))
        @test :Saw in names && :RLPF in names
        # la sortie pointe le nœud signifiant (safety stage retiré)
        @test g2.nodes[g2.output_id].ugen === :RLPF
        @test any(l -> occursin("RLPF", l), Ressac.explain_genome(g2))
    end

    @testset "genome_from_dsl handles a feedback export" begin
        txt = "@synth :x (freq=200, sustain=0.5) feedback() do fb\n" *
              "    n1 = ugen(:Saw, fb)\n" *
              "    ugen(:Limiter, ugen(:LeakDC, ugen(:Sanitize, n1)), 0.95)\nend\n"
        g = Ressac.genome_from_dsl(txt)
        @test g isa Ressac.Genome
        @test any(n -> n.ugen === :FbIn, values(g.nodes))
    end

    @testset "explain_synth_file works on a DSL export without embedded genome" begin
        # exactement le format metalressone (DSL, pas de commentaire génome)
        txt = "@synth :m (freq=280, sustain=2.9) begin\n" *
              "    n1 = ugen(:Saw, :freq)\n" *
              "    n2 = ugen(:Formlet, n1, 1000, 0.3, 1.1)\n" *
              "    ugen(:Limiter, ugen(:LeakDC, ugen(:Sanitize, n2)), 0.95)\nend\n"
        path = tempname() * ".jl"; write(path, txt)
        lines = Ressac.explain_synth_file(path)
        @test any(l -> occursin("Formlet", l) || occursin("résonateur", l), lines)
        @test any(l -> occursin("métallique", l), lines)   # cue structurel
        rm(path; force = true)
    end

    @testset "unparseable synth → graceful note" begin
        path = tempname() * ".jl"
        write(path, "this is not a synth at all\n")
        lines = Ressac.explain_synth_file(path)
        @test any(l -> occursin("impossible", l), lines)
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
