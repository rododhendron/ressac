using Test
using Ressac

@testset "synth roles — templates + role_fit" begin
    @testset "roles are registered with the right shape" begin
        @test !isempty(Ressac.ROLE_ORDER)
        @test :basse in Ressac.ROLE_ORDER
        for name in Ressac.ROLE_ORDER
            r = Ressac.role(name)
            @test length(r.target) == Ressac.N_DESCRIPTORS
            @test length(r.weights) == Ressac.N_DESCRIPTORS
            @test all(0.0 .<= r.target .<= 1.0)
        end
    end

    @testset "a role's own target scores ~1" begin
        for name in Ressac.ROLE_ORDER
            r = Ressac.role(name)
            @test Ressac.role_fit(r.target, r) ≈ 1.0 atol = 1e-9
        end
    end

    @testset "a bass-like sound prefers :basse over :voix" begin
        # sombre, beaucoup de graves, tonal, pitch clair (cf. mesure sine80)
        bassy = [0.05, 0.85, 0.02, 0.5, 0.7, 0.95]
        @test Ressac.role_fit(bassy, :basse) > Ressac.role_fit(bassy, :voix)
        @test Ressac.role_fit(bassy, :basse) > Ressac.role_fit(bassy, :lead)
    end

    @testset "a percussive sound prefers :kick over :nappe" begin
        # attaque vive, tenue faible (décroît vite), graves présents
        perc = [0.25, 0.7, 0.3, 0.95, 0.1, 0.4]
        @test Ressac.role_fit(perc, :kick) > Ressac.role_fit(perc, :nappe)
    end

    @testset "a bright tonal sound prefers :voix/:lead over :basse" begin
        bright = [0.75, 0.05, 0.1, 0.5, 0.8, 0.9]
        @test Ressac.role_fit(bright, :voix) > Ressac.role_fit(bright, :basse)
        @test Ressac.role_fit(bright, :lead) > Ressac.role_fit(bright, :basse)
    end

    @testset "unknown role name → fit 0" begin
        @test Ressac.role_fit([0.5, 0.5, 0.5, 0.5, 0.5, 0.5], :nope) == 0.0
    end

    @testset "cycle_role walks none → roles → none" begin
        seen = Union{Nothing,Symbol}[]
        cur = nothing
        for _ in 1:(length(Ressac.ROLE_ORDER) + 1)
            cur = Ressac.cycle_role(cur, 1); push!(seen, cur)
        end
        @test seen[1] == Ressac.ROLE_ORDER[1]
        @test seen[end] === nothing            # revient à « pas de rôle »
        @test Ressac.cycle_role(nothing, -1) == Ressac.ROLE_ORDER[end]
    end

    @testset "refine_role pulls the target toward positive examples" begin
        r = Ressac.role(:basse)
        # exemple positif très grave/bassy → la cible doit s'en rapprocher
        pos = [0.0, 1.0, 0.0, 0.4, 0.8, 1.0]
        r2 = Ressac.refine_role(r, Vector{Float64}[pos], Vector{Float64}[]; rate = 0.5)
        @test Ressac.role_fit(pos, r2) > Ressac.role_fit(pos, r)   # mieux ajusté
        @test r2.target != r.target
        @test Ressac.role(:basse).target == r.target              # template intact
    end
end
