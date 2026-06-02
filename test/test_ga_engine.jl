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
