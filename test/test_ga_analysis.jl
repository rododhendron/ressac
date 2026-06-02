using Test
using Ressac
using Random

@testset "ga_analysis" begin
    cand(g) = Ressac.Candidate(g, 0.0)

    @testset "genome_distance: identical = 0, different > 0" begin
        a = Ressac.archetype(:drone_grave)
        b = Ressac.archetype(:drone_grave)
        @test Ressac.genome_distance(a, b) == 0.0
        c = Ressac.archetype(:noise_perc)
        @test Ressac.genome_distance(a, c) > 0.0
    end

    @testset "cluster_population groups identical genomes together" begin
        a = cand(Ressac.archetype(:drone_grave))
        b = cand(Ressac.archetype(:drone_grave))
        c = cand(Ressac.archetype(:noise_perc))
        ids = Ressac.cluster_population([a, b, c]; threshold = 0.5)
        @test ids[1] == ids[2]      # the two drones cluster
        @test ids[3] != ids[1]      # the noise is its own cluster
    end

    @testset "cluster ids are 1-based + contiguous" begin
        pop = Ressac.init_population(Ressac.archetype(:drone_grave), 9,
                                     MersenneTwister(1); radius = 0.6)
        ids = Ressac.cluster_population(pop.candidates)
        @test minimum(ids) == 1
        @test Set(ids) == Set(1:maximum(ids))
    end

    @testset "gene_distribution counts UGens, most common first" begin
        pop = Ressac.init_population(Ressac.archetype(:drone_grave), 9,
                                     MersenneTwister(2); radius = 0.0)
        dist = Ressac.gene_distribution(pop.candidates)
        @test !isempty(dist)
        @test issorted([-p.second for p in dist])      # descending counts
        # drone_grave is Saw→RLPF; radius 0 keeps structure → both appear
        names = [p.first for p in dist]
        @test :Saw in names || :RLPF in names
    end
end
