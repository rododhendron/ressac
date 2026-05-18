using Test
using Ressac

@testset "algebra" begin
    # Helper: build a Pattern{Int} of one event per cycle with the given value,
    # cycle-aligned. Useful for testing without depending on mini-notation.
    const_pat(v::Int) = Ressac.pure(v)

    # Helper: build a Pattern{Int} with a known cycle: two halves [a, b].
    function half_pat(a::Int, b::Int)
        Pattern{Int}((s::Rational, e::Rational) -> begin
            evs = Event{Int}[]
            n_start = floor(Int, s)
            n_stop  = ceil(Int, e)
            for n in n_start:(n_stop - 1)
                # left half [n, n+1/2)
                ls = max(Rational{Int64}(n), s)
                le = min(Rational{Int64}(n) + 1//2, e)
                ls < le && push!(evs, Event{Int}(ls, le, a))
                # right half [n+1/2, n+1)
                rs = max(Rational{Int64}(n) + 1//2, s)
                re = min(Rational{Int64}(n + 1), e)
                rs < re && push!(evs, Event{Int}(rs, re, b))
            end
            evs
        end)
    end

    @testset "Pattern + scalar shifts every value" begin
        p = const_pat(3)
        @test (p + 12)(0//1, 1//1) == [Event(0//1, 1//1, 15)]
        # Reflected: scalar + Pattern works too.
        @test (12 + p)(0//1, 1//1) == [Event(0//1, 1//1, 15)]
    end

    @testset "Pattern - scalar / * scalar / / scalar" begin
        p = const_pat(10)
        @test (p - 3)(0//1, 1//1)  == [Event(0//1, 1//1, 7)]
        @test (3 - p)(0//1, 1//1)  == [Event(0//1, 1//1, -7)]
        @test (p * 2)(0//1, 1//1)  == [Event(0//1, 1//1, 20)]
        @test (2 * p)(0//1, 1//1)  == [Event(0//1, 1//1, 20)]
        # Division uses the standard Julia semantics: Int/Int → Float64.
        # We compare numerically.
        evs = (p / 2)(0//1, 1//1)
        @test length(evs) == 1
        @test evs[1].value ≈ 5.0
    end

    @testset "Pattern + Pattern: arc intersection + value sum" begin
        # p1 = [0, 1/2): 1, [1/2, 1): 2
        # p2 = [0, 1): 10
        # p1 + p2 = [0, 1/2): 11, [1/2, 1): 12
        p1 = half_pat(1, 2)
        p2 = const_pat(10)
        @test (p1 + p2)(0//1, 1//1) == [
            Event(0//1, 1//2, 11),
            Event(1//2, 1//1, 12),
        ]
    end

    @testset "Pattern + Pattern: misaligned arcs subdivide" begin
        # p1 = [0, 1/2): 1, [1/2, 1): 2
        # p2 = [0, 1/4): 100, [1/4, 1): 200   (asymmetric split)
        p1 = half_pat(1, 2)
        p2 = Pattern{Int}((s::Rational, e::Rational) -> begin
            evs = Event{Int}[]
            push!(evs, Event{Int}(0//1, 1//4, 100))
            push!(evs, Event{Int}(1//4, 1//1, 200))
            filter!(ev -> ev.start < e && ev.stop > s, evs)
            evs
        end)
        @test (p1 + p2)(0//1, 1//1) == [
            Event(0//1, 1//4, 101),
            Event(1//4, 1//2, 201),
            Event(1//2, 1//1, 202),
        ]
    end

    @testset "Identity: p + 0 ≡ p" begin
        p = half_pat(1, 2)
        @test query(p + 0, 0, 2) == query(p, 0, 2)
    end

    @testset "Identity: p * 1 ≡ p" begin
        p = half_pat(3, 7)
        @test query(p * 1, 0, 2) == query(p, 0, 2)
    end

    @testset "Commutativity of +" begin
        p = half_pat(1, 2)
        q = half_pat(10, 20)
        @test query(p + q, 0, 3) == query(q + p, 0, 3)
    end

    @testset "Associativity of +" begin
        p = half_pat(1, 2)
        q = const_pat(100)
        r = half_pat(1000, 2000)
        @test query((p + q) + r, 0, 2) == query(p + (q + r), 0, 2)
    end

    @testset "mask: gate Pattern{T} with Pattern{Bool}" begin
        # Half-pattern of values [1, 2]; mask keeps only the first half.
        p = half_pat(1, 2)
        q = Pattern{Bool}((s::Rational, e::Rational) -> begin
            evs = Event{Bool}[]
            push!(evs, Event{Bool}(0//1, 1//2, true))
            push!(evs, Event{Bool}(1//2, 1//1, false))
            filter!(ev -> ev.start < e && ev.stop > s, evs)
            evs
        end)
        @test mask(p, q)(0//1, 1//1) == [Event(0//1, 1//2, 1)]
    end

    @testset "mask: all-true is identity on the window" begin
        p = half_pat(5, 6)
        all_true = Pattern{Bool}((s::Rational, e::Rational) ->
            [Event{Bool}(s, e, true)])
        @test mask(p, all_true)(0//1, 1//1) == query(p, 0, 1)
    end

    @testset "mask: all-false produces empty" begin
        p = half_pat(5, 6)
        all_false = Pattern{Bool}((s::Rational, e::Rational) ->
            [Event{Bool}(s, e, false)])
        @test mask(p, all_false)(0//1, 1//1) == Event{Int}[]
    end
end
