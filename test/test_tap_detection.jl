# Tests for the tap-period detector — pins down the heuristic
# constants so future tuning doesn't silently regress the
# musically-important cases.
#
# The detector accepts a vector of tap timestamps and returns either:
#   • `nothing` — no repeating loop confidently detected → caller falls
#     back to single-bar quantization
#   • NamedTuple(period, n_bars, steps, confidence, n_hits, votes,
#     threshold) — the best-fit period and a step quantization

@testset "tap detection" begin
    detect = Ressac._detect_tap_period

    @testset "regression: 3 reps of 'bd ~ ~ bd ~ ~ ~ ~' (8-step jersey)" begin
        # 3 bars × 2 hits per bar at positions 0 and 3/8.
        # Expect: p=1.0 wins, S=8 perfect snap.
        evs = [0.0, 0.375, 1.0, 1.375, 2.0, 2.375]
        r = detect(evs)
        @test r !== nothing
        @test isapprox(r.period, 1.0; atol = 1e-9)
        @test r.steps == 8
        @test r.confidence > 0.7
        # Votes should peak at bins 1 and 4 (positions 0 and 3/8).
        @test r.votes[1] == 3 && r.votes[4] == 3
    end

    @testset "regression: 2 reps of 'bd ~ ~ bd' (the n_reps floor case)" begin
        # 4 events at the same positions, only 2 reps. Used to fail
        # the n_reps_best < 1.5 floor; now passes at 1.25.
        evs = [0.0, 0.375, 1.0, 1.375]
        r = detect(evs)
        @test r !== nothing
        @test isapprox(r.period, 1.0; atol = 1e-9)
        @test r.steps == 8
    end

    @testset "rejects sub-divisor (jersey case)" begin
        # 3-rep jersey: p=0.375 is a candidate (matches the inter-bd
        # gap inside one bar) but it's a SUB-divisor of the true
        # period (1.0s). hot_threshold=⌈2*n_reps/3⌉ should reject it
        # because the bins don't all reach the threshold.
        evs = [0.0, 0.375, 1.0, 1.375, 2.0, 2.375]
        r = detect(evs)
        @test r !== nothing
        # If sub-divisor won, period would be 0.375 and steps would be
        # tiny (1 hit per bar). The 8-step output proves the bar
        # detection picked the right scale.
        @test r.period > 0.5
    end

    @testset "3 reps of '~ bd ~ bd' (kick on backbeat)" begin
        evs = [0.5, 1.0, 1.5, 2.0, 2.5]
        # 5 events at every 0.5s — even spacing. The detector picks the
        # period where multiple hits fall in distinct bins.
        r = detect(evs)
        @test r !== nothing
        @test r.period >= 0.4   # reasonable bar length, not the sub-IOI
    end

    @testset "evenly-spaced taps (no rep evidence) — does not fall apart" begin
        # 4 evenly spaced. Acceptable to either return nothing (fall
        # back) OR detect a small period — what matters is that the
        # result is musically sensible (not a 32-step degenerate).
        evs = [0.0, 0.25, 0.5, 0.75]
        r = detect(evs)
        if r !== nothing
            @test r.steps <= 16          # not over-resolved
            @test r.confidence <= 1.0
            @test r.n_bars >= 1
        end
    end

    @testset "too few taps returns nothing" begin
        @test detect(Float64[]) === nothing
        @test detect([0.0]) === nothing
        @test detect([0.0, 0.5]) === nothing
        @test detect([0.0, 0.5, 1.0]) === nothing   # n=3, under the n<4 floor
    end

    @testset "cps hint biases toward bar-aligned periods" begin
        # User taps a steady stream of 16ths at 120 BPM cps=0.5
        # (bar = 2s, 8 hits per bar).
        bar = 2.0
        evs = [i * bar / 8 for i in 0:23]  # 3 bars × 8 hits
        r_nohint = detect(evs)
        r_hint   = detect(evs; cps_hint = 0.5)
        @test r_nohint !== nothing
        @test r_hint   !== nothing
        # With the hint, the detector should snap closer to bar-multiples.
        bar_ratio = r_hint.period / bar
        @test abs(bar_ratio - round(bar_ratio)) < 0.1
    end

    @testset "step inference picks the SMALLEST perfect-snap S" begin
        # Hits at 0 and 0.5 of a 1.0s bar — both S=2 (too small,
        # below min_S=2) and S=4, 8, 16 give perfect snap. We expect
        # the smallest valid: S=4 (one of the musical_steps).
        evs = [0.0, 0.5, 1.0, 1.5, 2.0, 2.5]
        r = detect(evs)
        @test r !== nothing
        @test r.steps == 4
    end

    @testset "step inference snaps jersey to S=8, not S=4 or S=3" begin
        # Hits at 0 and 0.375 — S=4 gives err 0.5 (bad), S=8 gives 0.
        # The algo should prefer S=8 even though S=3 has avg err 0.06.
        evs = [0.0, 0.375, 1.0, 1.375, 2.0, 2.375]
        r = detect(evs)
        @test r !== nothing
        @test r.steps == 8
    end

    @testset "confidence in [0, 1] and decreases with jitter" begin
        clean = [0.0, 0.5, 1.0, 1.5, 2.0, 2.5]
        # Add ±0.05s jitter
        jittered = clean .+ [0.0, 0.04, -0.03, 0.05, -0.04, 0.02]
        rc = detect(clean)
        rj = detect(jittered)
        @test rc !== nothing && rj !== nothing
        @test 0.0 <= rc.confidence <= 1.0
        @test 0.0 <= rj.confidence <= 1.0
        @test rc.confidence >= rj.confidence
    end
end
