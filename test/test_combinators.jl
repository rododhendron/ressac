using Test
using Ressac

@testset "combinators" begin
    @testset "pure" begin
        p = pure(:bd)
        @test p(0//1, 1//1) == [Event(0//1, 1//1, :bd)]
        @test p(0//1, 2//1) == [Event(0//1, 1//1, :bd), Event(1//1, 2//1, :bd)]
        # Partial window: event is clipped, not excluded.
        @test p(1//4, 3//4) == [Event(1//4, 3//4, :bd)]
        # Multi-cycle windows starting mid-cycle.
        @test p(1//2, 5//2) == [
            Event(1//2, 1//1, :bd),
            Event(1//1, 2//1, :bd),
            Event(2//1, 5//2, :bd),
        ]
    end

    @testset "silence" begin
        @test silence(Symbol)(0//1, 1//1) == Event{Symbol}[]
        @test silence(Int)(0//1, 10//1) == Event{Int}[]
        @test silence(Symbol)(0//1, 1//1) isa Vector{Event{Symbol}}
    end

    @testset "fast" begin
        p = fast(2, pure(:bd))
        evs = p(0//1, 1//1)
        @test evs == [Event(0//1, 1//2, :bd), Event(1//2, 1//1, :bd)]

        # fast(4, ...) packs 4 events per cycle.
        @test length(fast(4, pure(:x))(0//1, 1//1)) == 4

        # Zero factor is rejected.
        @test_throws ArgumentError fast(0, pure(:bd))
    end

    @testset "slow" begin
        p = slow(2, pure(:bd))
        # slow(2, pure) emits one event spanning two cycles.
        @test p(0//1, 2//1) == [Event(0//1, 2//1, :bd)]
    end

    @testset "density alias" begin
        @test density === fast
    end

    @testset "rev" begin
        # Build a pattern with two distinguishable events in one cycle.
        p = fast(2, cat([pure(:a), pure(:b)]))
        # Sanity: p produces [a in [0, 1/2), b in [1/2, 1)].
        @test p(0//1, 1//1) == [Event(0//1, 1//2, :a), Event(1//2, 1//1, :b)]
        # rev mirrors within the cycle.
        @test rev(p)(0//1, 1//1) == [Event(0//1, 1//2, :b), Event(1//2, 1//1, :a)]
    end

    @testset "every" begin
        # Every other cycle, double the speed.
        ev = every(2, x -> fast(2, x), pure(:bd))
        # Cycle 0 (transformed): 2 events.
        @test length(ev(0//1, 1//1)) == 2
        # Cycle 1 (untouched): 1 event.
        @test ev(1//1, 2//1) == [Event(1//1, 2//1, :bd)]
        # n=0 is rejected.
        @test_throws ArgumentError every(0, identity, pure(:bd))
    end

    @testset "stack" begin
        s = stack(pure(:bd), pure(:sn))
        evs = s(0//1, 1//1)
        @test length(evs) == 2
        # Both events span the full cycle; order between equal-start events
        # is unspecified, so compare as a set of values.
        @test sort([ev.value for ev in evs]) == [:bd, :sn]
        @test all(ev -> ev.start == 0//1 && ev.stop == 1//1, evs)
    end

    @testset "cat" begin
        c = cat([pure(:a), pure(:b)])
        @test c(0//1, 2//1) == [Event(0//1, 1//1, :a), Event(1//1, 2//1, :b)]
        # Rotates back to ps[1] on cycle 2.
        @test c(2//1, 3//1) == [Event(2//1, 3//1, :a)]
        # Varargs form mirrors the Vector form.
        @test cat(pure(:a), pure(:b))(0//1, 2//1) == c(0//1, 2//1)
        @test_throws ArgumentError cat(Pattern{Symbol}[])
    end

    @testset "algebraic laws" begin
        p = fast(3, cat([pure(:x), pure(:y), pure(:z)]))

        @testset "fast(2, slow(2, p)) ≡ p" begin
            @test query(fast(2, slow(2, p)), 0, 3) == query(p, 0, 3)
        end

        @testset "rev(rev(p)) ≡ p" begin
            @test query(rev(rev(p)), 0, 3) == query(p, 0, 3)
        end

        @testset "stack(p, silence) ≡ p" begin
            @test query(stack(p, silence(Symbol)), 0, 3) == query(p, 0, 3)
        end
    end

    @testset "curried fast(n) is fast(n, _)" begin
        # The single-arg form should return a function that, applied to a
        # Pattern, gives the same result as the two-arg form.
        curried = fast(2)
        @test curried isa Function
        @test query(curried(pure(:bd)), 0, 1) == query(fast(2, pure(:bd)), 0, 1)
        # Pipe usage matches.
        @test query(pure(:bd) |> fast(2), 0, 1) == query(fast(2, pure(:bd)), 0, 1)
    end
end
