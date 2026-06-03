using Test
using Ressac

@testset "genome — types + catalogue" begin
    @testset "Arg constructors" begin
        @test Ressac.ConstArg(2.0).value == 2.0
        @test Ressac.NodeRef(3).id == 3
        @test Ressac.ControlRef(:freq).name === :freq
    end

    @testset "empty genome has a fresh id counter" begin
        g = Ressac.Genome()
        @test isempty(g.nodes)
        @test g.next_id == 1
    end

    @testset "add_node! returns the id and stores the node" begin
        g = Ressac.Genome()
        id = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        @test id == 1
        @test g.nodes[id].ugen === :Saw
        @test g.nodes[id].rate === :ar
        @test g.next_id == 2
        id2 = Ressac.add_node!(g, :SinOsc, :ar, Ressac.Arg[Ressac.ConstArg(440.0)])
        @test id2 == 2
    end

    @testset "catalogue: builtin UGens are registered" begin
        spec = Ressac.ugen_spec(:Saw)
        @test spec !== nothing
        @test :ar in spec.rates
        @test spec.role === :source
        @test length(spec.slots) >= 1
        @test Ressac.ugen_spec(:NopeNotReal) === nothing
    end

    @testset "catalogue slot has range + default" begin
        rlpf = Ressac.ugen_spec(:RLPF)
        cut = rlpf.slots[2]   # signal in, cutoff, q
        @test cut.name === :freq
        @test cut.lo < cut.hi
    end
end

@testset "genome — expanded catalogue (chaos + effects + shapers)" begin
    @testset "chaotic generators are registered as sources" begin
        for nm in (:LorenzL, :HenonL, :LatoocarfianL, :CuspL, :Logistic, :FBSineL)
            spec = Ressac.ugen_spec(nm)
            @test spec !== nothing
            @test spec.role === :source
        end
    end

    @testset "a chaotic source renders + is audible" begin
        g = Ressac.Genome()
        c = Ressac.add_node!(g, :LorenzL, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        g.output_id = c
        @test occursin("LorenzL.ar(freq)", Ressac.render_synthdef(g, :x))
        @test Ressac.genome_is_audible(g)
    end

    @testset "waveshapers render their method form" begin
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        f = Ressac.add_node!(g, :Fold2, :ar, Ressac.Arg[Ressac.NodeRef(s), Ressac.ConstArg(1.5)])
        g.output_id = f
        @test occursin("(Saw.ar(freq)).fold2(1.5)", Ressac.render_synthdef(g, :x))
    end

    @testset "effects + filters present" begin
        @test Ressac.ugen_spec(:FreeVerb).role === :filter
        @test Ressac.ugen_spec(:BPF).role === :filter
        @test Ressac.ugen_spec(:MoogFF).role === :filter
    end
end
