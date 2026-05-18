using Test
using Ressac

@testset "core" begin
    @testset "Event — construction and equality" begin
        ev = Event(0//1, 1//1, :bd)
        @test ev.start == 0//1
        @test ev.stop  == 1//1
        @test ev.value == :bd
        # Immutable structs with bitstype fields compare by value out of the box.
        @test ev == Event(0//1, 1//1, :bd)
        @test ev != Event(0//1, 1//1, :sn)
        @test ev != Event(0//1, 2//1, :bd)
        @test hash(ev) == hash(Event(0//1, 1//1, :bd))
    end

    @testset "Pattern — callable and query alias" begin
        # A trivial pattern: returns one event spanning the whole query window.
        p = Pattern{Int}((s, e) -> [Event{Int}(s, e, 42)])

        @test p(0//1, 1//1) == [Event(0//1, 1//1, 42)]
        @test query(p, 0//1, 1//1) == p(0//1, 1//1)

        # `Real` arguments are coerced to Rational{Int64}.
        @test query(p, 0, 1) == [Event(0//1, 1//1, 42)]
        @test query(p, 0.0, 0.5) == [Event(0//1, 1//2, 42)]
    end

    @testset "_to_rat coercions" begin
        @test Ressac._to_rat(2) === 2//1
        @test Ressac._to_rat(3//4) === 3//4
        @test Ressac._to_rat(0.5) === 1//2
        @test Ressac._to_rat(0.25) === 1//4
    end
end
