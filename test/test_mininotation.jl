using Test
using Ressac

@testset "mininotation" begin
    @testset "single atom is constant over each cycle" begin
        p = parse_minino("bd")
        @test p(0//1, 1//1) == [Event(0//1, 1//1, :bd)]
        @test p(0//1, 2//1) == [
            Event(0//1, 1//1, :bd),
            Event(1//1, 2//1, :bd),
        ]
    end

    @testset "sequence splits the cycle evenly" begin
        p = parse_minino("bd hh sn hh")
        @test p(0//1, 1//1) == [
            Event(0//1, 1//4, :bd),
            Event(1//4, 1//2, :hh),
            Event(1//2, 3//4, :sn),
            Event(3//4, 1//1, :hh),
        ]
    end

    @testset "tilde is a silence" begin
        p = parse_minino("bd ~ sn ~")
        @test p(0//1, 1//1) == [
            Event(0//1, 1//4, :bd),
            Event(1//2, 3//4, :sn),
        ]
    end

    @testset "brackets subdivide a single slot" begin
        # 3 top-level slots; the middle subdivides into two hits.
        p = parse_minino("bd [hh hh] sn")
        @test p(0//1, 1//1) == [
            Event(0//1, 1//3, :bd),
            Event(1//3, 1//2, :hh),
            Event(1//2, 2//3, :hh),
            Event(2//3, 1//1, :sn),
        ]
    end

    @testset "angle brackets alternate per cycle" begin
        p = parse_minino("<bd sn cp>")
        @test p(0//1, 1//1) == [Event(0//1, 1//1, :bd)]
        @test p(1//1, 2//1) == [Event(1//1, 2//1, :sn)]
        @test p(2//1, 3//1) == [Event(2//1, 3//1, :cp)]
        # Cycle 3 wraps back to bd.
        @test p(3//1, 4//1) == [Event(3//1, 4//1, :bd)]
    end

    @testset "star repeats the unit inside its slot" begin
        # Standalone: 4 events in a cycle.
        p = parse_minino("bd*4")
        @test p(0//1, 1//1) == [
            Event(0//1, 1//4, :bd),
            Event(1//4, 1//2, :bd),
            Event(1//2, 3//4, :bd),
            Event(3//4, 1//1, :bd),
        ]
        # Inside a sequence: bd*2 occupies half a cycle and fires twice.
        p2 = parse_minino("bd*2 sn")
        @test p2(0//1, 1//1) == [
            Event(0//1, 1//4, :bd),
            Event(1//4, 1//2, :bd),
            Event(1//2, 1//1, :sn),
        ]
    end

    @testset "euclidean rhythm (3,8) distributes evenly" begin
        p = parse_minino("bd(3,8)")
        # Canonical (3,8) is x . . x . . x . — hits at steps 0, 3, 6.
        @test p(0//1, 1//1) == [
            Event(0//1, 1//8, :bd),
            Event(3//8, 4//8, :bd),
            Event(6//8, 7//8, :bd),
        ]
    end

    @testset "bang weights stretch over multiple slots" begin
        # bd!2 sn: 3 weighted slots total; bd spans 2/3, sn spans 1/3.
        p = parse_minino("bd!2 sn")
        @test p(0//1, 1//1) == [
            Event(0//1, 2//3, :bd),
            Event(2//3, 1//1, :sn),
        ]
    end

    @testset "@p_str macro is equivalent to parse_minino" begin
        @test (p"bd hh sn hh")(0//1, 1//1) == parse_minino("bd hh sn hh")(0//1, 1//1)
    end

    @testset "sample notation keeps the colon in the symbol" begin
        p = parse_minino("bd:1 bd:2")
        @test p(0//1, 1//1) == [
            Event(0//1, 1//2, Symbol("bd:1")),
            Event(1//2, 1//1, Symbol("bd:2")),
        ]
    end

    @testset "nested brackets recurse" begin
        # [a [b c]]: a takes half, [b c] takes half (split into quarters).
        p = parse_minino("[a [b c]]")
        @test p(0//1, 1//1) == [
            Event(0//1, 1//2, :a),
            Event(1//2, 3//4, :b),
            Event(3//4, 1//1, :c),
        ]
    end

    @testset "parse errors carry context" begin
        @test_throws ArgumentError parse_minino("bd [hh")        # unclosed bracket
        @test_throws ArgumentError parse_minino("bd*")           # missing repeat count
        @test_throws ArgumentError parse_minino("bd(3 8)")       # missing comma in euclid
        @test_throws ArgumentError parse_minino("bd #")          # invalid character
    end
end
