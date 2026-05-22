using Test
using Ressac

@testset "tui_hints" begin
    @testset "_fuzzy_score exact prefix is tight" begin
        @test Ressac._fuzzy_score("sa", "samples") == 0
    end

    @testset "_fuzzy_score gap counts" begin
        @test Ressac._fuzzy_score("sa", "snares") == 1
    end

    @testset "_fuzzy_score no match → nothing" begin
        @test Ressac._fuzzy_score("xy", "samples") === nothing
    end

    @testset "_fuzzy_score empty query → 0" begin
        @test Ressac._fuzzy_score("", "anything") == 0
    end

    @testset "_fuzzy_score case-insensitive" begin
        @test Ressac._fuzzy_score("BD", "bd_kick") == 0
    end
end
