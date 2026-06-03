using Test
using Ressac
using Random

@testset "ga_engine" begin
    base() = Ressac.archetype(:drone_grave)

    @testset "init_population fills N valid candidates" begin
        pop = Ressac.init_population(base(), 9, MersenneTwister(1); radius = 0.5)
        @test length(pop.candidates) == 9
        @test pop.generation == 0
        for c in pop.candidates
            @test isempty(Ressac.validate(c.genome))
            @test c.weight == 0.0
        end
    end

    @testset "favor!/devalue! grade the weight (cumulative)" begin
        pop = Ressac.init_population(base(), 9, MersenneTwister(2); radius = 0.5)
        Ressac.favor!(pop, 1)
        Ressac.devalue!(pop, 2)
        @test pop.candidates[1].weight == 1.0
        @test pop.candidates[2].weight == -1.0
        Ressac.favor!(pop, 1)              # presser à nouveau = plus fort
        @test pop.candidates[1].weight == 2.0
        for _ in 1:10; Ressac.favor!(pop, 1); end
        @test pop.candidates[1].weight == 3.0   # borné à +3
    end

    @testset "next_generation preserves a favored elite genome" begin
        pop = Ressac.init_population(base(), 9, MersenneTwister(3); radius = 0.5)
        pop.strategy = :breeding
        Ressac.favor!(pop, 4)
        elite_src = Ressac.render_synthdef(pop.candidates[4].genome, :x)
        Ressac.next_generation!(pop, MersenneTwister(3))
        @test pop.generation == 1
        @test length(pop.candidates) == 9
        srcs = [Ressac.render_synthdef(c.genome, :x) for c in pop.candidates]
        @test elite_src in srcs                  # élitisme
        @test all(c -> c.weight == 0.0, pop.candidates)   # notes réinitialisées
    end

    @testset "mono-favori = divergence (all children valid)" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(4); radius = 0.3)
        Ressac.favor!(pop, 1)
        Ressac.next_generation!(pop, MersenneTwister(4))
        @test all(c -> isempty(Ressac.validate(c.genome)), pop.candidates)
    end

    @testset "no favorites → regenerate from base, still valid" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(5); radius = 0.5)
        Ressac.next_generation!(pop, MersenneTwister(5))
        @test pop.generation == 1
        @test all(c -> isempty(Ressac.validate(c.genome)), pop.candidates)
    end

    @testset "next_generation! is deterministic under fixed seed" begin
        p1 = Ressac.init_population(base(), 6, MersenneTwister(6); radius = 0.5)
        p2 = Ressac.init_population(base(), 6, MersenneTwister(6); radius = 0.5)
        Ressac.favor!(p1, 1); Ressac.favor!(p2, 1)
        Ressac.next_generation!(p1, MersenneTwister(77))
        Ressac.next_generation!(p2, MersenneTwister(77))
        s1 = [Ressac.render_synthdef(c.genome, :x) for c in p1.candidates]
        s2 = [Ressac.render_synthdef(c.genome, :x) for c in p2.candidates]
        @test s1 == s2
    end
end

@testset "ga_engine — tune mode (frozen structure)" begin
    base() = Ressac.archetype(:drone_grave)

    # Signature structurelle : multiset d'UGens + nb de nœuds + nb d'arêtes
    # NodeRef. Invariante sous une mutation paramétrique pure.
    function _struct_sig(g::Ressac.Genome)
        ugens = sort([String(n.ugen) for n in values(g.nodes)])
        edges = sum(count(a -> a isa Ressac.NodeRef, n.args) for n in values(g.nodes); init = 0)
        return (ugens, length(g.nodes), edges)
    end

    @testset "tune_generation! freezes the graph, anchor stays at #1" begin
        pop = Ressac.init_population(base(), 9, MersenneTwister(10); radius = 0.6)
        anchor = pop.candidates[3].genome
        sig0 = _struct_sig(anchor)
        anchor_src = Ressac.render_synthdef(anchor, :x)
        Ressac.tune_generation!(pop, anchor, MersenneTwister(10))
        @test pop.generation == 1
        @test length(pop.candidates) == 9
        # l'ancre est conservée telle quelle en tête
        @test Ressac.render_synthdef(pop.candidates[1].genome, :x) == anchor_src
        # toute la génération partage la structure de l'ancre (gelée)
        for c in pop.candidates
            @test _struct_sig(c.genome) == sig0
            @test isempty(Ressac.validate(c.genome))
        end
    end

    @testset "tune children actually differ from the anchor" begin
        pop = Ressac.init_population(base(), 9, MersenneTwister(11); radius = 0.6)
        anchor = pop.candidates[1].genome
        anchor_src = Ressac.render_synthdef(anchor, :x)
        Ressac.tune_generation!(pop, anchor, MersenneTwister(11))
        # au moins un enfant (hors ancre) diffère par ses constantes/contrôles
        others = [Ressac.render_synthdef(c.genome, :x) for c in pop.candidates[2:end]]
        @test any(s -> s != anchor_src, others)
    end
end

@testset "ga_engine — default strategy is active inference (bayesian)" begin
    pop = Ressac.init_population(Ressac.archetype(:drone_grave), 6, MersenneTwister(1))
    @test pop.strategy === :bayesian
end

@testset "ga_engine — lineage + GA params" begin
    base() = Ressac.archetype(:drone_grave)

    @testset "init assigns unique ids + 'graine' origin" begin
        pop = Ressac.init_population(base(), 9, MersenneTwister(1); radius = 0.5)
        ids = [c.id for c in pop.candidates]
        @test length(unique(ids)) == 9
        @test all(c -> c.origin == "graine", pop.candidates)
        @test pop.gen_size == 9
    end

    @testset "next_generation records origins (élite / muté / ×)" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(2); radius = 0.5)
        pop.strategy = :breeding
        Ressac.favor!(pop, 1); Ressac.favor!(pop, 2)
        Ressac.next_generation!(pop, MersenneTwister(2))
        origins = [c.origin for c in pop.candidates]
        @test any(o -> startswith(o, "élite"), origins)
        @test any(o -> startswith(o, "muté") || startswith(o, "×"), origins)
        @test all(c -> c.id > 0, pop.candidates)
    end

    @testset "lineage_chain walks ancestry newest-first" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(3); radius = 0.5)
        Ressac.favor!(pop, 1)
        Ressac.next_generation!(pop, MersenneTwister(3))
        Ressac.favor!(pop, 1)
        Ressac.next_generation!(pop, MersenneTwister(3))
        chain = Ressac.lineage_chain(pop, pop.candidates[1].id)
        @test chain[1].id == pop.candidates[1].id
        @test length(chain) >= 2          # at least itself + a parent
    end

    @testset "GA params drive next_generation (gen_size, elitism)" begin
        pop = Ressac.init_population(base(), 9, MersenneTwister(4); radius = 0.5)
        pop.strategy = :breeding
        pop.gen_size = 6
        pop.elitism = 2
        Ressac.favor!(pop, 1); Ressac.favor!(pop, 2); Ressac.favor!(pop, 3)
        Ressac.next_generation!(pop, MersenneTwister(4))
        @test length(pop.candidates) == 6
        # two elites preserved as-is
        @test count(c -> startswith(c.origin, "élite"), pop.candidates) == 2
    end

    @testset "crossover_prob = 0 → only mutations" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(5); radius = 0.5)
        pop.crossover_prob = 0.0
        Ressac.favor!(pop, 1); Ressac.favor!(pop, 2)
        Ressac.next_generation!(pop, MersenneTwister(5))
        @test !any(c -> startswith(c.origin, "×"), pop.candidates)
    end
end

@testset "ga_engine — selection strategies" begin
    base() = Ressac.archetype(:drone_grave)
    function pop_with(strat)
        pop = Ressac.init_population(base(), 6, MersenneTwister(7); radius = 0.5)
        pop.strategy = strat
        Ressac.favor!(pop, 1); Ressac.favor!(pop, 2)
        return pop
    end

    @testset "every strategy yields gen_size valid candidates" begin
        for strat in Ressac.GA_STRATEGIES
            pop = pop_with(strat)
            Ressac.next_generation!(pop, MersenneTwister(7))
            @test length(pop.candidates) == 6
            @test all(c -> isempty(Ressac.validate(c.genome)), pop.candidates)
            @test all(c -> c.id > 0, pop.candidates)
        end
    end

    @testset "champion: all children descend from the single best favorite" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(8); radius = 0.5)
        pop.strategy = :champion
        Ressac.favor!(pop, 3)
        champ_id = pop.candidates[3].id
        Ressac.next_generation!(pop, MersenneTwister(8))
        for c in pop.candidates
            @test pop.lineage[c.id].parents == [champ_id]
        end
    end

    @testset "cooling shrinks the divergence radius each generation" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(9); radius = 0.8)
        pop.strategy = :cooling
        Ressac.favor!(pop, 1)
        r0 = pop.radius
        Ressac.next_generation!(pop, MersenneTwister(9))
        @test pop.radius < r0
    end

    @testset "novelty children are valid + distinct" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(10); radius = 0.5)
        pop.strategy = :novelty
        Ressac.next_generation!(pop, MersenneTwister(10))
        @test all(c -> isempty(Ressac.validate(c.genome)), pop.candidates)
    end
end

@testset "ga_engine — bayesian + quality-diversity strategies" begin
    base() = Ressac.archetype(:drone_grave)

    @testset "genome_feature_vec has stable length" begin
        a = Ressac.genome_feature_vec(Ressac.archetype(:drone_grave))
        b = Ressac.genome_feature_vec(Ressac.archetype(:noise_perc))
        @test length(a) == length(b)
        @test length(a) > 3
    end

    @testset "bayesian: produces gen_size valid + audible candidates" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(11); radius = 0.5)
        pop.strategy = :bayesian
        Ressac.favor!(pop, 1); Ressac.devalue!(pop, 2)
        Ressac.next_generation!(pop, MersenneTwister(11))
        @test length(pop.candidates) == 6
        @test all(c -> isempty(Ressac.validate(c.genome)), pop.candidates)
        @test all(c -> Ressac.genome_is_audible(c.genome), pop.candidates)
        @test haskey(pop.state, :bo_examples)
    end

    @testset "bayesian accumulates rated examples across generations" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(12); radius = 0.5)
        pop.strategy = :bayesian
        Ressac.favor!(pop, 1)
        Ressac.next_generation!(pop, MersenneTwister(12))
        n1 = length(pop.state[:bo_examples])
        Ressac.favor!(pop, 1)
        Ressac.next_generation!(pop, MersenneTwister(12))
        @test length(pop.state[:bo_examples]) > n1
    end

    @testset "quality-diversity builds a behavior archive" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(13); radius = 0.6)
        pop.strategy = :quality_diversity
        Ressac.favor!(pop, 1)
        Ressac.next_generation!(pop, MersenneTwister(13))
        @test length(pop.candidates) == 6
        @test all(c -> isempty(Ressac.validate(c.genome)), pop.candidates)
        @test haskey(pop.state, :qd_archive)
        @test !isempty(pop.state[:qd_archive])
    end

    @testset "all 8 strategies stay valid + audible" begin
        for strat in Ressac.GA_STRATEGIES
            pop = Ressac.init_population(base(), 6, MersenneTwister(14); radius = 0.5)
            pop.strategy = strat
            Ressac.favor!(pop, 1); Ressac.favor!(pop, 3)
            Ressac.next_generation!(pop, MersenneTwister(14))
            @test all(c -> isempty(Ressac.validate(c.genome)) &&
                           Ressac.genome_is_audible(c.genome), pop.candidates)
        end
    end
end

@testset "ga_engine — hall of fame + diverge" begin
    base() = Ressac.archetype(:drone_grave)

    @testset "favored genomes are archived in the hall" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(20); radius = 0.5)
        Ressac.favor!(pop, 1); Ressac.favor!(pop, 3)
        Ressac.next_generation!(pop, MersenneTwister(20))
        @test haskey(pop.state, :hall)
        @test length(pop.state[:hall]) >= 2
    end

    @testset "diverge! re-mutates a diverse pool, stays valid + audible" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(21); radius = 0.3)
        Ressac.favor!(pop, 1)
        Ressac.next_generation!(pop, MersenneTwister(21))   # seeds the hall
        gen = pop.generation
        Ressac.diverge!(pop, MersenneTwister(21))
        @test pop.generation == gen + 1
        @test length(pop.candidates) == 6
        @test all(c -> isempty(Ressac.validate(c.genome)) &&
                       Ressac.genome_is_audible(c.genome), pop.candidates)
        @test all(c -> c.origin == "divergé", pop.candidates)
    end
end

@testset "ga_engine — explore when nothing is rated" begin
    base() = Ressac.archetype(:drone_grave)

    @testset "n with no ratings explores from the current pop (drift)" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(40); radius = 0.4)
        src0 = [Ressac.render_synthdef(c.genome, :x) for c in pop.candidates]
        Ressac.next_generation!(pop, MersenneTwister(40))   # nothing rated
        @test all(c -> c.origin == "exploré", pop.candidates)
        @test all(c -> isempty(Ressac.validate(c.genome)) &&
                       Ressac.genome_is_audible(c.genome), pop.candidates)
        src1 = [Ressac.render_synthdef(c.genome, :x) for c in pop.candidates]
        @test src1 != src0                  # actually moved
    end
end
