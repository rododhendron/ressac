using Test
using Ressac

@testset "genome — validity + repair" begin
    function _saw_genome()
        g = Ressac.Genome()
        id = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        g.output_id = id
        return g
    end

    @testset "a well-formed genome validates clean" begin
        @test isempty(Ressac.validate(_saw_genome()))
    end

    @testset "missing output is reported" begin
        g = _saw_genome(); g.output_id = 0
        @test any(occursin("output", e) for e in Ressac.validate(g))
    end

    @testset "dangling NodeRef is reported" begin
        g = _saw_genome()
        push!(g.nodes[g.output_id].args, Ressac.NodeRef(999))
        @test any(occursin("dangling", e) for e in Ressac.validate(g))
    end

    @testset "repair! drops dangling refs + restores an output" begin
        g = _saw_genome()
        push!(g.nodes[g.output_id].args, Ressac.NodeRef(999))
        g.output_id = 0
        Ressac.repair!(g)
        @test isempty(Ressac.validate(g))
        @test g.output_id != 0
    end

    @testset "repair! pads missing args with slot defaults" begin
        g = Ressac.Genome()
        id = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        g.output_id = id
        Ressac.repair!(g)
        @test length(g.nodes[id].args) == 3          # in, freq, rq
        @test isempty(Ressac.validate(g))
    end

    @testset "repair! breaks a cycle" begin
        g = Ressac.Genome()
        a = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.ControlRef(:freq),
                             Ressac.ConstArg(1200.0), Ressac.ConstArg(0.5)])
        b = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(a),
                             Ressac.ConstArg(800.0), Ressac.ConstArg(0.5)])
        g.nodes[a].args[1] = Ressac.NodeRef(b)        # a→b→a cycle
        g.output_id = b
        Ressac.repair!(g)
        @test isempty(Ressac.validate(g))
    end
end
