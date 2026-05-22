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

    @testset "_fuzzy_rank sorts by (score, length, lexico)" begin
        out = Ressac._fuzzy_rank("sa", ["samples", "snares", "savings"])
        @test out == ["samples", "savings", "snares"]
    end

    @testset "_fuzzy_rank skips non-matches" begin
        @test Ressac._fuzzy_rank("xy", ["foo", "bar"]) == String[]
    end

    @testset "_fuzzy_rank stable with empty query" begin
        out = Ressac._fuzzy_rank("", ["b", "a", "c"])
        @test out == ["a", "b", "c"]
    end

    @testset "_completion_context inside p\" returns :mininotation" begin
        @test Ressac._completion_context("p\"kic", 6) === :mininotation
    end

    @testset "_completion_context after closed p\" returns :default" begin
        @test Ressac._completion_context("p\"bd\" |> fast", 14) === :default
    end

    @testset "_completion_context mid-buffer mini-notation" begin
        @test Ressac._completion_context("@d1 p\"bd hh", 11) === :mininotation
    end

    @testset "_completion_context amp\" is not an opener" begin
        @test Ressac._completion_context("amp\"junk", 8) === :default
    end

    @testset "_completion_context m\" (mininotation macro)" begin
        @test Ressac._completion_context("m\"kick", 7) === :mininotation
    end
end
