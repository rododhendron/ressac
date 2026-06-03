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

    @testset "duplication stays bounded (safety guard, overflow allowed)" begin
        rng = MersenneTwister(31)
        g = _g()
        for _ in 1:30; Ressac.op_duplicate_subgraph!(g, rng); Ressac.repair!(g); end
        # le cap dur a sauté (on autorise l'overflow) ; reste un garde-fou de
        # sécurité à 30 nœuds → pas de runaway infini.
        @test length(g.nodes) <= 60
    end
end

@testset "genome — énergie / coût métabolique" begin
    @testset "un générateur coûte plus qu'une modulation" begin
        @test Ressac.node_cost(:Saw) > Ressac.node_cost(:SinOscKR)
        @test Ressac.node_cost(:SinOscKR) <= Ressac.node_cost(:RLPF)
        @test Ressac.node_cost(:FreeVerb) > Ressac.node_cost(:Saw)   # surcharge
    end

    @testset "genome_energy somme les coûts des nœuds" begin
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        f = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                             Ressac.ConstArg(1000.0), Ressac.ConstArg(0.5)])
        g.output_id = f
        @test Ressac.genome_energy(g) ≈ Ressac.node_cost(:Saw) + Ressac.node_cost(:RLPF)
    end

    @testset "le ressort élague au-dessus de la cible" begin
        # gros génome + cible basse → la mutation structurelle tend à réduire
        # l'énergie en moyenne (pression de parcimonie).
        rng = MersenneTwister(7)
        big = Ressac.Genome()
        s = Ressac.add_node!(big, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        big.output_id = s
        for _ in 1:8; Ressac.op_duplicate_subgraph!(big, rng); Ressac.repair!(big); end
        e0 = Ressac.genome_energy(big)
        drops = 0
        for t in 1:40
            child = Ressac.mutate(big, MersenneTwister(t); radius = 0.8,
                                  target = 3.0, stiffness = 0.6)
            Ressac.genome_energy(child) < e0 && (drops += 1)
        end
        @test drops > 20            # majorité des mutations réduisent l'énergie
    end

    @testset "le ressort fait croître sous la cible" begin
        rng = MersenneTwister(9)
        small = Ressac.Genome()
        s = Ressac.add_node!(small, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        small.output_id = s
        e0 = Ressac.genome_energy(small)
        grows = 0
        for t in 1:40
            child = Ressac.mutate(small, MersenneTwister(t); radius = 0.8,
                                  target = 20.0, stiffness = 0.6)
            Ressac.genome_energy(child) > e0 && (grows += 1)
        end
        @test grows > 20            # majorité des mutations augmentent l'énergie
    end

    @testset "Population porte les réglages d'énergie par défaut" begin
        pop = Ressac.init_population(Ressac.archetype(:drone_grave), 6, MersenneTwister(1))
        @test pop.energy_target == Ressac._DEFAULT_ENERGY_TARGET
        @test pop.stiffness == Ressac._DEFAULT_STIFFNESS
    end
end

@testset "genome — good moves + directional guidance" begin
    base() = Ressac.archetype(:pluck)

    @testset "every good move keeps the genome valid + audible" begin
        rng = MersenneTwister(50)
        for (name, _) in Ressac.GOOD_MOVES
            g = base()
            Ressac.apply_good_move!(g, rng; move = name)
            @test isempty(Ressac.validate(g))
            @test Ressac.genome_is_audible(g)
        end
    end

    @testset "dir_grave lowers the freq control" begin
        g = base(); g.controls[:freq] = 200.0
        Ressac.apply_guidance!(g, :grave, MersenneTwister(1))
        @test Ressac.control(g, :freq) < 200.0
    end

    @testset "dir_aigu raises the freq control" begin
        g = base(); g.controls[:freq] = 200.0
        Ressac.apply_guidance!(g, :aigu, MersenneTwister(1))
        @test Ressac.control(g, :freq) > 200.0
    end

    @testset "every direction stays valid + audible; :none is a no-op" begin
        rng = MersenneTwister(51)
        for dir in Ressac.GUIDANCE_ORDER
            g = Ressac.archetype(:drone_grave)
            before = Ressac.render_synthdef(g, :x)
            Ressac.apply_guidance!(g, dir, rng)
            @test isempty(Ressac.validate(g))
            @test Ressac.genome_is_audible(g)
            dir === :none && @test Ressac.render_synthdef(g, :x) == before
        end
    end
end
