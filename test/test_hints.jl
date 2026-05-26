using Test
using Ressac

mutable struct _HintsMockClient
    sent::Vector{Vector{UInt8}}
end
_HintsMockClient() = _HintsMockClient(Vector{UInt8}[])
Ressac.send_osc(c::_HintsMockClient, bytes::Vector{UInt8}) = push!(c.sent, bytes)

@testset "hints" begin
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

    @testset "_buffer_candidates(:default) includes combinators and macros" begin
        cands = Ressac._buffer_candidates(:default)
        @test "fast" in cands
        @test "gain" in cands
        @test "@d1" in cands
        @test "@d64" in cands
    end

    @testset "_buffer_candidates(:mininotation) excludes combinators and macros" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        empty!(Ressac._INSTRUMENT_REGISTRY)
        empty!(Ressac._SYNTH_REGISTRY)
        try
            Ressac.register_sample!(Ressac.SampleEntry(:kicky, "p",
                "/x", ["/x"], Dict{String,Any}()))
            cands = Ressac._buffer_candidates(:mininotation)
            @test "kicky" in cands
            @test !("fast" in cands)
            @test !("@d1" in cands)
        finally
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    # _compute_completions(::LiveModel) testsets removed in phase-3
    # cleanup. The RessacApp path uses `_try_ex_autocomplete!` from
    # autocomplete.jl (see test_modal_helpers.jl for its structural
    # coverage — every regex dispatcher extracts ≥ 1 verb, etc.).
end
