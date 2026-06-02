using Test
using Ressac
using Random

@testset "genome — parametric operators" begin
    function _g()
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        f = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                             Ressac.ConstArg(1000.0), Ressac.ConstArg(0.5)])
        g.output_id = f
        return g
    end

    @testset "op_perturb_const moves a constant within slot range" begin
        rng = MersenneTwister(42)
        g = _g()
        Ressac.op_perturb_const!(g, rng; radius = 1.0)
        @test isempty(Ressac.validate(g))
        for (id, n) in g.nodes, (i, a) in enumerate(n.args)
            a isa Ressac.ConstArg || continue
            sp = Ressac.ugen_spec(n.ugen).slots[i]
            @test sp.lo <= a.value <= sp.hi
        end
    end

    @testset "op_change_rate keeps the rate legal" begin
        rng = MersenneTwister(7)
        g = _g()
        Ressac.op_change_rate!(g, rng)
        @test isempty(Ressac.validate(g))
    end

    @testset "mutate is deterministic under a fixed seed" begin
        a = Ressac.mutate(_g(), MersenneTwister(99); radius = 0.5)
        b = Ressac.mutate(_g(), MersenneTwister(99); radius = 0.5)
        @test Ressac.render_synthdef(a, :x) == Ressac.render_synthdef(b, :x)
    end

    @testset "mutate always yields a valid genome" begin
        rng = MersenneTwister(1)
        for _ in 1:50
            g = Ressac.mutate(_g(), rng; radius = rand(rng))
            @test isempty(Ressac.validate(g))
        end
    end

    @testset "low radius keeps structure (node count stable)" begin
        rng = MersenneTwister(3)
        g = Ressac.mutate(_g(), rng; radius = 0.0)
        @test length(g.nodes) == 2     # radius 0 = paramétrique seul
    end
end
