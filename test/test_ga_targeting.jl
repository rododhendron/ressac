using Test
using Ressac
using Random

@testset "ga targeting — big-pool → top-k" begin
    base() = Ressac.archetype(:drone_grave)

    @testset "generate_pool makes N children without touching the population" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(1))
        before = copy(pop.candidates)
        pool = Ressac.generate_pool(pop, MersenneTwister(1), 30)
        @test length(pool) == 30
        @test pop.candidates == before              # population intacte
        @test all(c -> isempty(Ressac.validate(c.genome)), pool)
    end

    @testset "harvest_topk! keeps the k best by role_fit (injected analyzer)" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(2))
        pop.state[:role] = :basse
        pop.state[:role_strength] = 3.0
        basse = Ressac.role(:basse).target
        voix  = Ressac.role(:voix).target
        # analyseur simulé : 1 candidat sur 5 « sonne basse », le reste « voix »
        calls = Ref(0)
        # ~1 candidat sur 3 « sonne basse » → plus de basses que k
        fake = function (genomes)
            calls[] += 1
            return [i % 3 == 1 ? copy(basse) : copy(voix) for i in 1:length(genomes)]
        end
        Ressac.harvest_topk!(pop, MersenneTwister(2); pool_size = 25, k = 6, analyze = fake)
        @test calls[] == 1
        @test length(pop.candidates) == 6
        @test pop.generation == 1
        # tous les retenus doivent être des « basses » mesurées (fit élevé)
        store = pop.state[:descr]
        for c in pop.candidates
            @test haskey(store, c.id)
            @test Ressac.role_fit(store[c.id], :basse) > 0.9
        end
    end

    @testset "rank_topk orders by effective weight" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(3))
        pop.state[:role] = :basse
        pop.state[:role_strength] = 2.0
        store = Ressac._descr_store(pop)
        cands = pop.candidates
        # candidat 1 = basse parfaite, les autres = neutres
        store[cands[1].id] = copy(Ressac.role(:basse).target)
        for c in cands[2:end]; store[c.id] = fill(0.5, Ressac.N_DESCRIPTORS); end
        top = Ressac.rank_topk(pop, cands, 3)
        @test length(top) == 3
        @test top[1].id == cands[1].id              # la basse parfaite en tête
    end
end
