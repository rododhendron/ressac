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

    @testset "favor!/devalue! write weights" begin
        pop = Ressac.init_population(base(), 9, MersenneTwister(2); radius = 0.5)
        Ressac.favor!(pop, 1)
        Ressac.devalue!(pop, 2)
        @test pop.candidates[1].weight > 0
        @test pop.candidates[2].weight < 0
        Ressac.favor!(pop, 1)              # re-presser annule
        @test pop.candidates[1].weight == 0.0
    end

    @testset "next_generation preserves a favored elite genome" begin
        pop = Ressac.init_population(base(), 9, MersenneTwister(3); radius = 0.5)
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
