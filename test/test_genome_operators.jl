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

@testset "genome — structural operators + crossover" begin
    function _g()
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        f = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                             Ressac.ConstArg(1000.0), Ressac.ConstArg(0.5)])
        g.output_id = f
        return g
    end

    @testset "op_insert_node! grows the graph and stays valid" begin
        rng = MersenneTwister(11)
        g = _g(); n0 = length(g.nodes)
        Ressac.op_insert_node!(g, rng)
        @test length(g.nodes) == n0 + 1
        @test isempty(Ressac.validate(g))
    end

    @testset "op_remove_node! shrinks or no-ops, always valid" begin
        rng = MersenneTwister(12)
        g = _g()
        Ressac.op_remove_node!(g, rng)
        @test isempty(Ressac.validate(g))
        @test length(g.nodes) >= 1
    end

    @testset "op_swap_ugen! valid after repair (op defers arity to repair!)" begin
        rng = MersenneTwister(13)
        g = _g()
        Ressac.op_swap_ugen!(g, rng)
        Ressac.repair!(g)
        @test isempty(Ressac.validate(g))
    end

    @testset "op_rewire! valid after repair (op defers cycle-break to repair!)" begin
        rng = MersenneTwister(14)
        g = _g()
        Ressac.op_rewire!(g, rng)
        Ressac.repair!(g)
        @test isempty(Ressac.validate(g))
    end

    @testset "op_graft_mod! keeps it valid" begin
        rng = MersenneTwister(15)
        g = _g()
        Ressac.op_graft_mod!(g, rng)
        @test isempty(Ressac.validate(g))
    end

    @testset "op_add_feedback! inserts a single FbIn, stays valid" begin
        rng = MersenneTwister(20)
        g = _g()
        Ressac.op_add_feedback!(g, rng)
        @test isempty(Ressac.validate(g))
        fbs = count(n -> n.ugen === :FbIn, values(g.nodes))
        @test fbs == 1
        Ressac.op_add_feedback!(g, rng)
        @test count(n -> n.ugen === :FbIn, values(g.nodes)) == 1
        @test occursin("LocalIn", Ressac.render_synthdef(g, :x))
    end

    @testset "crossover yields a valid child blending both" begin
        rng = MersenneTwister(16)
        a = _g()
        b = Ressac.archetype(:fm_bell)
        child = Ressac.crossover(a, b, rng)
        @test isempty(Ressac.validate(child))
    end

    @testset "high-radius mutate can change structure" begin
        rng = MersenneTwister(123)
        changed = false
        for _ in 1:30
            g = Ressac.mutate(_g(), rng; radius = 1.0)
            length(g.nodes) != 2 && (changed = true)
        end
        @test changed
    end
end

@testset "genome — duplication operator" begin
    function _g()
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        f = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                             Ressac.ConstArg(1000.0), Ressac.ConstArg(0.5)])
        g.output_id = f
        return g
    end

    @testset "op_duplicate_subgraph! clones a group + stays valid" begin
        rng = MersenneTwister(30)
        g = _g(); n0 = length(g.nodes)
        Ressac.op_duplicate_subgraph!(g, rng)
        Ressac.repair!(g)
        @test length(g.nodes) > n0          # grew (clone + Mix)
        @test isempty(Ressac.validate(g))
        @test Ressac.genome_is_audible(g)
    end

    @testset "duplication is bounded (no runaway)" begin
        rng = MersenneTwister(31)
        g = _g()
        for _ in 1:30; Ressac.op_duplicate_subgraph!(g, rng); Ressac.repair!(g); end
        @test length(g.nodes) <= 20         # guard caps growth
    end
end
