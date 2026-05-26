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

    @testset "slow(0) throws ArgumentError eagerly" begin
        @test_throws ArgumentError slow(0, pure(:bd))
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

    @testset "curried slow(n) is slow(n, _)" begin
        curried = slow(2)
        @test curried isa Function
        @test query(pure(:bd) |> slow(2), 0, 2) == query(slow(2, pure(:bd)), 0, 2)
    end

    @testset "curried every(n, f) is every(n, f, _)" begin
        curried = every(2, rev)
        @test curried isa Function
        @test query(pure(:bd) |> every(2, rev), 0, 2) ==
              query(every(2, rev, pure(:bd)), 0, 2)
    end

    @testset "curried stack(q) is stack(_, q)" begin
        @test query(pure(:bd) |> stack(pure(:sn)), 0, 1) ==
              query(stack(pure(:bd), pure(:sn)), 0, 1)
    end

    # ── Drop-the-`p` ergonomics ─────────────────────────────────────
    # Every curried combinator accepts AbstractString as its pattern
    # arg and auto-parses via mini-notation, so users can write
    # `@d1 "bd hh sn hh" |> gain(0.5)` without the `p"…"` prefix.
    @testset "_as_pattern — three-way promotion" begin
        ref = parse_minino("bd hh sn hh")
        @test query(Ressac._as_pattern("bd hh sn hh"), 0, 1) == query(ref, 0, 1)
        @test query(Ressac._as_pattern(:bd),           0, 1) == query(pure(:bd), 0, 1)
        @test Ressac._as_pattern(ref) === ref          # identity on Pattern
    end

    @testset "curried combinators accept bare strings" begin
        # One assert per combinator that gained string acceptance —
        # equivalence with the canonical `p"…"` form.
        @test query("bd hh sn hh" |> fast(2), 0, 1) ==
              query(p"bd hh sn hh" |> fast(2), 0, 1)
        @test query("bd hh sn hh" |> slow(2), 0, 2) ==
              query(p"bd hh sn hh" |> slow(2), 0, 2)
        @test query("bd hh sn hh" |> every(2, rev), 0, 2) ==
              query(p"bd hh sn hh" |> every(2, rev), 0, 2)
        @test query("bd hh sn hh" |> off(1//8, fast(2)), 0, 1) ==
              query(p"bd hh sn hh" |> off(1//8, fast(2)), 0, 1)
        @test query("bd hh sn hh" |> iter(2), 0, 2) ==
              query(p"bd hh sn hh" |> iter(2), 0, 2)
    end

    @testset "gate accepts a bare-string mask" begin
        @test query(gate(:bd, "1 0 1 0"), 0, 1) ==
              query(gate(:bd, p"1 0 1 0"), 0, 1)
        # Curried form too: `:bd |> gate("1 0 1 0")`.
        @test query(:bd |> gate("1 0 1 0"), 0, 1) ==
              query(gate(:bd, p"1 0 1 0"), 0, 1)
    end

    # ── Sprint 1 — Tidal-parity batch ───────────────────────────────
    @testset "early / late shift events in time" begin
        evs = query(pure(:bd) |> early(1//4), 0, 1)
        # pure fires at 0; early(1/4) pulls it to -1/4. Outside [0,1).
        # Cycle window query returns nothing; the event is now in cycle -1.
        # So check cycle (-1, 1) instead.
        evs2 = query(pure(:bd) |> early(1//4), -1, 1)
        @test any(ev -> ev.start == -1//4, evs2)
        # late shifts in the other direction.
        evs3 = query(pure(:bd) |> late(1//4), 0, 2)
        @test any(ev -> ev.start == 1//4, evs3)
    end

    @testset "ply repeats each event in place" begin
        # ply(3) on "bd sn" → bd bd bd sn sn sn over one cycle.
        evs = query(ply(3, p"bd sn"), 0, 1)
        @test length(evs) == 6
        @test [ev.value for ev in evs] == [:bd, :bd, :bd, :sn, :sn, :sn]
    end

    @testset "runp produces 0..n-1 once per cycle" begin
        # `run` collides with Base.run, so the export is `runp`.
        evs = query(runp(4), 0, 1)
        @test [ev.value for ev in evs] == [0, 1, 2, 3]
        @test [ev.start for ev in evs] == [0//1, 1//4, 2//4, 3//4]
        # The qualified path Ressac.run still works for code copied
        # from Tidal/Strudel.
        @test query(Ressac.run(4), 0, 1) == evs
    end

    @testset "choose is deterministic per cycle" begin
        p = choose([:bd, :sn, :hh])
        # Same cycle window → same value (deterministic hash-based pick).
        evs1 = query(p, 0, 1)
        evs2 = query(p, 0, 1)
        @test evs1[1].value === evs2[1].value
    end

    @testset "seq crams patterns into one cycle (fastcat)" begin
        @test query(seq([pure(:bd), pure(:sn)]), 0, 1) ==
              query(p"bd sn", 0, 1)
    end

    @testset "iterBack rotates opposite direction" begin
        # iter(2) on "bd sn cp hh" rotates forward each cycle.
        # iterBack should rotate backward.
        fwd  = query(p"bd sn cp hh" |> iter(4),     0, 4)
        back = query(p"bd sn cp hh" |> iterBack(4), 0, 4)
        @test length(fwd) == length(back) == 16
        # First cycle is the same (no rotation yet).
        @test [ev.value for ev in fwd[1:4]] == [ev.value for ev in back[1:4]]
        # Second cycle differs.
        @test [ev.value for ev in fwd[5:8]] != [ev.value for ev in back[5:8]]
    end

    @testset "lastOf fires on the LAST cycle of every period" begin
        # lastOf(3, rev) → rev on cycles 2, 5, 8, … (every == cycles 0, 3, 6, …)
        evs2 = query(p"bd sn cp" |> lastOf(3, rev), 2, 3)
        # On cycle 2 (last of 3), pattern is reversed.
        @test [ev.value for ev in evs2] == [:cp, :sn, :bd]
        evs0 = query(p"bd sn cp" |> lastOf(3, rev), 0, 1)
        # On cycle 0, NOT reversed.
        @test [ev.value for ev in evs0] == [:bd, :sn, :cp]
    end

    @testset "firstOf is an alias of every" begin
        @test query(p"bd sn cp" |> firstOf(2, rev), 0, 4) ==
              query(p"bd sn cp" |> every(2, rev),  0, 4)
    end

    # ── Chord syntax in mini-notation: [a,b,c] = parallel events ──
    @testset "[a,b] chord: two atomic events with same arc" begin
        evs = (parse_minino("[bd,sn]"))(0//1, 1//1)
        @test length(evs) == 2
        @test all(ev -> ev.start == 0//1 && ev.stop == 1//1, evs)
        @test sort([ev.value for ev in evs]) == [:bd, :sn]
    end

    @testset "[a b, c] chord: sequence in parallel with atom" begin
        evs = (parse_minino("[bd hh, sn]"))(0//1, 1//1)
        # bd hh sequence: bd in [0, 1/2), hh in [1/2, 1).
        # sn in parallel: spans full [0, 1).
        @test length(evs) == 3
        @test any(ev -> ev.value === :bd && ev.start == 0//1, evs)
        @test any(ev -> ev.value === :hh && ev.start == 1//2, evs)
        @test any(ev -> ev.value === :sn && ev.stop == 1//1, evs)
    end

    @testset "[a, b, c] three-voice chord" begin
        evs = (parse_minino("[bd, hh, sn]"))(0//1, 1//1)
        @test length(evs) == 3
        @test all(ev -> ev.start == 0//1 && ev.stop == 1//1, evs)
    end

    @testset "chord top-level (no outer brackets)" begin
        # `"bd, sn"` at the top should still create a chord.
        evs = (parse_minino("bd, sn"))(0//1, 1//1)
        @test length(evs) == 2
        @test sort([ev.value for ev in evs]) == [:bd, :sn]
    end

    # ── Continuous signals ─────────────────────────────────────────
    @testset "sine() midpoint values are correct" begin
        p = sine() |> segment(4)
        evs = query(p, 0, 1)
        @test length(evs) == 4
        # Midpoints at 1/8, 3/8, 5/8, 7/8 cycle:
        # sin(2π · 1/8) = sin(π/4) ≈ √2/2 ≈ 0.707
        @test isapprox(evs[1].value, sqrt(2)/2; atol=1e-3)
        @test isapprox(evs[3].value, -sqrt(2)/2; atol=1e-3)
    end

    @testset "saw() ramps 0→1 over a cycle" begin
        p = saw() |> segment(4)
        vals = [ev.value for ev in query(p, 0, 1)]
        @test all(diff(vals) .> 0)  # strictly increasing
        @test 0.0 < vals[1] < vals[end] < 1.0
    end

    @testset "square() bipolar on the half-cycle" begin
        p = square() |> segment(4)
        vals = [ev.value for ev in query(p, 0, 1)]
        @test vals[1:2] == [0.0, 0.0]
        @test vals[3:4] == [1.0, 1.0]
    end

    @testset "range_pat remaps to target interval" begin
        # saw() outputs [0, 1) at midpoints. range_pat(-1..1 → lo..hi)
        # uses (val+1)/2 — so val 0 maps to lo+(hi-lo)·0.5 = midpoint.
        p = saw() |> range_pat(100, 1000) |> segment(2)
        vals = [ev.value for ev in query(p, 0, 1)]
        @test all(100 <= v <= 1000 for v in vals)
    end

    @testset "rand_pat is deterministic per cycle" begin
        p1 = rand_pat() |> segment(2)
        a = [ev.value for ev in query(p1, 0, 1)]
        b = [ev.value for ev in query(p1, 0, 1)]
        @test a == b  # same query → same values
        # Cycles 0 and 1 differ.
        c = [ev.value for ev in query(p1, 1, 2)]
        @test a != c
    end

    @testset "perlin() output stays in [0, 1)" begin
        p = perlin() |> segment(8)
        vals = [ev.value for ev in query(p, 0, 4)]
        @test all(0 <= v < 1 for v in vals)
    end

    @testset "segment(n) produces n events per cycle" begin
        evs = query(sine() |> segment(7), 0, 2)
        @test length(evs) == 14
    end

    @testset "structPat — use bool mask structure with pattern's values" begin
        # Bool mask: 2 true slots out of 4.
        bools = parse_minino("1 0 1 0")
        bpat = Pattern{Bool}((s::Rational, e::Rational) -> begin
            inner = bools(s, e)
            [Event{Bool}(ev.start, ev.stop, ev.value === Symbol("1"))
             for ev in inner]
        end)
        # 4-event value source so structPat has enough material to
        # fill all true slots in the mask.
        vals = p"bd sn cp hh"
        evs = query(structPat(bpat, vals), 0, 1)
        @test length(evs) == 2          # 2 true slots in "1 0 1 0"
        # First true slot picks vals[1] = :bd, second picks vals[2] = :sn.
        @test [ev.value for ev in evs] == [:bd, :sn]
    end
end
