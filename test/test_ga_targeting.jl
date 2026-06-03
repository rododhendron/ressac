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

    @testset "cluster_descriptors separates well-separated groups" begin
        a = [0.1, 0.9, 0.1, 0.5, 0.5, 0.9]
        b = [0.9, 0.1, 0.1, 0.5, 0.5, 0.9]
        descrs = [a, a .+ 0.02, b, b .- 0.02, a .- 0.01]
        labels = Ressac.cluster_descriptors(descrs; threshold = 0.3)
        @test labels[1] == labels[2] == labels[5]    # groupe A
        @test labels[3] == labels[4]                 # groupe B
        @test labels[1] != labels[3]                 # A ≠ B
    end

    @testset "mode B (no role) returns timbral representatives" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(5))
        # 3 familles timbrales distinctes dans le pool
        groups = [[0.1,0.9,0.1,0.5,0.5,0.9], [0.9,0.1,0.1,0.5,0.5,0.9], [0.5,0.5,0.9,0.5,0.2,0.1]]
        fake = genomes -> [copy(groups[mod1(i, 3)]) .+ 0.01 .* (i ÷ 3) for i in 1:length(genomes)]
        Ressac.harvest_topk!(pop, MersenneTwister(5); pool_size = 24, k = 6, analyze = fake)
        @test length(pop.candidates) == 6
        store = pop.state[:descr]
        reps = [store[c.id] for c in pop.candidates]
        # les représentants couvrent ≥ 3 familles (pas tous identiques)
        labels = Ressac.cluster_descriptors(reps; threshold = 0.3)
        @test maximum(labels) >= 3
    end

    @testset "mode C : tagging refines the active role toward the example" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(6))
        pop.state[:role] = :basse
        store = Ressac._descr_store(pop)
        # candidat 1 mesuré « ultra-basse » ; on le tague +
        ultra = [0.0, 1.0, 0.0, 0.4, 0.8, 1.0]
        store[pop.candidates[1].id] = copy(ultra)
        fit_before = Ressac.role_fit(ultra, Ressac.effective_role(pop, :basse))
        @test Ressac.tag_example!(pop, 1, true)
        fit_after = Ressac.role_fit(ultra, Ressac.effective_role(pop, :basse))
        @test fit_after > fit_before                 # la cible s'est rapprochée
        @test Ressac.role(:basse).target == Ressac.role(:basse).target  # template intact
    end

    @testset "tag_example! is a no-op without an active role / measurement" begin
        pop = Ressac.init_population(base(), 6, MersenneTwister(7))
        @test Ressac.tag_example!(pop, 1, true) == false   # pas de rôle
        pop.state[:role] = :kick
        @test Ressac.tag_example!(pop, 1, true) == false   # pas de mesure
    end
end
