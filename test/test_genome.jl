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
