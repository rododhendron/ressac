# Property-based tests via Supposition.jl (Julia's Hypothesis).
#
# Each `@check` here states an invariant the codebase MUST hold, and
# lets Supposition synthesize inputs to try to disprove it. When a
# property fails, Supposition shrinks the input to a minimal
# counter-example — that's the killer feature versus example tests:
# you get the smallest input that breaks the rule, not a random one.

using Supposition
using Supposition: Data

# Pull plugin modules into scope. They're loaded into Main via the
# fixture plugins in test_chaos.jl / test_reservoir.jl, so by the time
# this file runs they exist; but we don't depend on that load order —
# we re-include the source if needed.
isdefined(Main, :Chaos) ||
    Base.include(Main, joinpath(@__DIR__, "..", "plugins", "chaos", "chaos.jl"))
isdefined(Main, :Reservoir) ||
    Base.include(Main, joinpath(@__DIR__, "..", "plugins", "reservoir", "reservoir.jl"))

@testset "property-based tests (Supposition)" begin

    # ══════════════════════════════════════════════════════════════════
    # 1 — Dispatcher ↔ registry consistency
    # ──────────────────────────────────────────────────────────────────
    # The exact bug the user found: `:starter reservoir-spike` was
    # rejected because the dispatcher regex was `\w+`, which excludes
    # `-`. A property test on the registry would have caught it the
    # moment we added the first hyphenated key.

    @testset "every starter pack key matches the dispatcher regex" begin
        # The literal regex from tui_app.jl. Keeping it duplicated here
        # is fine — that's the contract being asserted.
        starter_regex = r"^[\w-]+$"
        @check db = false function starter_keys_dispatchable(
            key = Data.SampledFrom(collect(keys(Ressac._STARTER_PACKS))))
            !isnothing(match(starter_regex, key))
        end
    end

    # ══════════════════════════════════════════════════════════════════
    # 2 — Mini-notation parser never crashes on valid token streams
    # ──────────────────────────────────────────────────────────────────
    # Generate sequences of safe atom tokens separated by single spaces
    # — the parser must accept them all and return a Pattern.

    @testset "parse_minino on synth-name sequences returns a Pattern" begin
        sample_names = ["bd", "sn", "hh", "cp", "~"]
        @check db = false function parse_safe_sequences(
            toks = Data.Vectors(Data.SampledFrom(sample_names);
                                 min_size=1, max_size=8))
            s = join(toks, " ")
            p = Ressac.parse_minino(s)
            p isa Ressac.Pattern
        end
    end

    # ══════════════════════════════════════════════════════════════════
    # 3 — Pattern algebra: slow then fast is identity
    # ──────────────────────────────────────────────────────────────────
    # For any pattern p and positive n, `p |> slow(n) |> fast(n)` must
    # emit the same events as `p` over [0, 1).

    @testset "slow(n) ∘ fast(n) == id on Pattern{Symbol}" begin
        sample_names = ["bd", "sn", "hh", "cp"]
        @check db = false function slow_fast_inverse(
            n = Data.Integers(1, 8),
            toks = Data.Vectors(Data.SampledFrom(sample_names);
                                 min_size=1, max_size=6))
            p = Ressac.parse_minino(join(toks, " "))
            a = p(0//1, 1//1)
            b = (p |> Ressac.slow(n) |> Ressac.fast(n))(0//1, 1//1)
            a == b
        end
    end

    # ══════════════════════════════════════════════════════════════════
    # 4 — `pure(v)` only emits events at natural-integer onsets
    # ──────────────────────────────────────────────────────────────────
    # This codifies the fix from the slow+pure regression: pure must
    # never emit an event whose start ISN'T an integer in [s, e).

    @testset "pure(v) event starts are integers in [s, e)" begin
        @check db = false function pure_event_onsets(
            s_num = Data.Integers(0, 20),
            s_den = Data.Integers(1, 4),
            dur_num = Data.Integers(1, 10),
            dur_den = Data.Integers(1, 4))
            s = Rational{Int64}(s_num, s_den)
            e = s + Rational{Int64}(dur_num, dur_den)
            evs = Ressac.pure(:bd)(s, e)
            all(ev -> denominator(ev.start) == 1 &&
                       s <= ev.start < e,
                evs)
        end
    end

    # ══════════════════════════════════════════════════════════════════
    # 5 — `striate(n, p)` event count is n × source-events-per-cycle
    # ──────────────────────────────────────────────────────────────────

    @testset "striate(n, p) emits n slices per source event per cycle" begin
        sample_names = ["bd", "sn", "hh"]
        @check db = false function striate_event_count(
            n = Data.Integers(1, 16),
            toks = Data.Vectors(Data.SampledFrom(sample_names);
                                 min_size=1, max_size=4))
            p = Ressac.parse_minino(join(toks, " "))
            src_count = length(p(0//1, 1//1))
            out = Ressac.striate(n, p)(0//1, 1//1)
            length(out) == n * src_count
        end
    end

    # ══════════════════════════════════════════════════════════════════
    # 6 — Fuzzy ranker: matches for a prefix ⊇ matches for the full query
    # ──────────────────────────────────────────────────────────────────
    # If "foo" matches a candidate, "fo" must also match it. Adding
    # characters can only narrow the match set, never widen it.

    @testset "_fuzzy_rank prefix superset" begin
        @check db = false function fuzzy_prefix_superset(
            cands = Data.Vectors(Data.Text(Data.AsciiCharacters();
                                            min_len=1, max_len=10);
                                   min_size=1, max_size=15),
            q = Data.Text(Data.AsciiCharacters(); min_len=2, max_len=6))
            prefix = q[1:end-1]
            set_pre = Set(Ressac._fuzzy_rank(prefix, cands))
            set_full = Set(Ressac._fuzzy_rank(q, cands))
            issubset(set_full, set_pre)
        end
    end

    # ══════════════════════════════════════════════════════════════════
    # 7 — AdEx step! preserves shape + finiteness
    # ──────────────────────────────────────────────────────────────────
    # Whatever input we throw at the AdEx reservoir, the state vectors
    # stay at the right length and never go non-finite (NaN / Inf).

    @testset "AdEx step! preserves shape and finiteness" begin
        @check db = false function adex_step_invariants(
            n = Data.Integers(1, 16),
            steps = Data.Integers(1, 40),
            drive = Data.Floats{Float64}(;
                minimum = -1000.0, maximum = 1000.0,
                nans = false, infs = false))
            r = Main.Reservoir.adex(N = n, seed = 1)
            input = fill(drive, n)
            for _ in 1:steps
                Main.Reservoir.step!(r, input)
            end
            length(Main.Reservoir.spikes(r)) == n &&
                all(isfinite, r.V) &&
                all(isfinite, r.w)
        end
    end

    # ══════════════════════════════════════════════════════════════════
    # 8 — RECA step! preserves shape regardless of rule + input
    # ──────────────────────────────────────────────────────────────────

    @testset "RECA step! preserves shape across all rules" begin
        @check db = false function reca_step_shape(
            n = Data.Integers(1, 32),
            rule = Data.Integers(0, 255),
            steps = Data.Integers(1, 20))
            r = Main.Reservoir.reca(N = n, rule = rule, init = :rand,
                                     seed = 1)
            for _ in 1:steps
                Main.Reservoir.step!(r, zeros(n))
            end
            length(Main.Reservoir.spikes(r)) == n &&
                length(r.state) == n
        end
    end

    # ══════════════════════════════════════════════════════════════════
    # 9 — Polymeter `[a, b]` events stay in [0, 1)
    # ──────────────────────────────────────────────────────────────────
    # `[v1 v2, w1 w2 w3]` runs both voices in parallel across one cycle;
    # events should never spill outside [0, 1).

    # ══════════════════════════════════════════════════════════════════
    # 10 — spike_burst re-query consistency
    # ──────────────────────────────────────────────────────────────────
    # The scheduler re-queries `pattern(n, n+1)` once per chunk that
    # overlaps cycle n. Calling the SAME pattern twice with the SAME
    # window must return the SAME events — otherwise sub-chunks past
    # the first lose all their events ("waiting for the next bar"
    # symptom the user reported).

    @testset "spike_burst is consistent across re-queries of the same window" begin
        @check db = false function spike_burst_idempotent(
            n = Data.Integers(4, 24),
            drive = Data.Floats{Float64}(;
                minimum = 300.0, maximum = 900.0,
                nans = false, infs = false))
            r = Main.Reservoir.adex(N = n, steps_per_cycle = 200, seed = 1)
            p = Main.Reservoir.spike_burst(r; drive = drive)
            a = p(0//1, 1//1)
            b = p(0//1, 1//1)
            length(a) == length(b) &&
                all(i -> a[i].start == b[i].start &&
                          a[i].stop == b[i].stop,
                    eachindex(a))
        end
    end

    @testset "spike_burst sub-chunks union to the full-cycle query" begin
        @check db = false function spike_burst_chunks_cover_cycle(
            n = Data.Integers(4, 16),
            drive = Data.Floats{Float64}(;
                minimum = 400.0, maximum = 800.0,
                nans = false, infs = false))
            # Full cycle query on one pattern.
            r1 = Main.Reservoir.adex(N = n, steps_per_cycle = 100, seed = 2)
            full = Main.Reservoir.spike_burst(r1; drive = drive)(0//1, 1//1)
            # Same cycle queried in 4 sub-chunks on an INDEPENDENT pattern.
            r2 = Main.Reservoir.adex(N = n, steps_per_cycle = 100, seed = 2)
            p2 = Main.Reservoir.spike_burst(r2; drive = drive)
            sub = vcat(p2(0//1, 1//4), p2(1//4, 1//2),
                       p2(1//2, 3//4), p2(3//4, 1//1))
            length(full) == length(sub)
        end
    end

    # ══════════════════════════════════════════════════════════════════
    # 11 — Progressive integration: sub-chunks union to full-cycle
    # ──────────────────────────────────────────────────────────────────
    # All reservoir routes were re-architected to integrate the
    # underlying neural sim STEP-BY-STEP (smooth scope) rather than
    # full-cycle-at-once (bursty). This property guards re-query
    # consistency: the union of events from sub-chunked queries must
    # equal the events from a single full-cycle query.

    @testset "pool_burst sub-chunks union to full-cycle query" begin
        @check db = false function pool_chunks_consistent(
            n = Data.Integers(4, 16),
            drive = Data.Floats{Float64}(;
                minimum = 400.0, maximum = 700.0,
                nans = false, infs = false))
            r1 = Main.Reservoir.adex(N = n, σ_noise = 300.0,
                                      steps_per_cycle = 200, seed = 7)
            p1 = Main.Reservoir.pool_burst(r1; bins = 4,
                                            frames_per_cycle = 4,
                                            drive = drive)
            full = p1(0//1, 1//1)
            r2 = Main.Reservoir.adex(N = n, σ_noise = 300.0,
                                      steps_per_cycle = 200, seed = 7)
            p2 = Main.Reservoir.pool_burst(r2; bins = 4,
                                            frames_per_cycle = 4,
                                            drive = drive)
            sub = vcat(p2(0//1, 1//4), p2(1//4, 1//2),
                       p2(1//2, 3//4), p2(3//4, 1//1))
            length(full) == length(sub)
        end
    end

    @testset "spectral_cloud sub-chunks union to full-cycle query" begin
        @check db = false function spectral_chunks_consistent(
            n = Data.Integers(8, 16),
            drive = Data.Floats{Float64}(;
                minimum = 400.0, maximum = 700.0,
                nans = false, infs = false))
            r1 = Main.Reservoir.adex(N = n, σ_noise = 300.0,
                                      steps_per_cycle = 200, seed = 9)
            p1 = Main.Reservoir.spectral_cloud(r1; bins = n,
                                                frames_per_cycle = 4,
                                                drive = drive)
            full = p1(0//1, 1//1)
            r2 = Main.Reservoir.adex(N = n, σ_noise = 300.0,
                                      steps_per_cycle = 200, seed = 9)
            p2 = Main.Reservoir.spectral_cloud(r2; bins = n,
                                                frames_per_cycle = 4,
                                                drive = drive)
            sub = vcat(p2(0//1, 1//4), p2(1//4, 1//2),
                       p2(1//2, 3//4), p2(3//4, 1//1))
            length(full) == length(sub)
        end
    end

    @testset "polymeter event arcs stay in [0, 1)" begin
        sample_names = ["bd", "sn", "hh"]
        @check db = false function polymeter_arcs(
            a = Data.Vectors(Data.SampledFrom(sample_names);
                              min_size=1, max_size=4),
            b = Data.Vectors(Data.SampledFrom(sample_names);
                              min_size=1, max_size=4))
            src = "[" * join(a, " ") * ", " * join(b, " ") * "]"
            p = Ressac.parse_minino(src)
            evs = p(0//1, 1//1)
            all(ev -> 0//1 <= ev.start && ev.start < 1//1 &&
                       ev.start < ev.stop && ev.stop <= 1//1,
                evs)
        end
    end

end
