# Tests for the reservoir plugin (plugins/reservoir/).
#
# Same fixture pattern as test_chaos.jl: a tiny fixture plugin loads
# the real reservoir.jl via the [julia] handler, exercising the full
# plugin-loading path before we test the module's API.

@testset "reservoir plugin" begin
    fixtures = joinpath(@__DIR__, "fixtures", "plugins")

    @testset "fixture loads the Reservoir module into Main" begin
        Ressac._load_plugins([fixtures])
        @test isdefined(Main, :Reservoir)
        @test isdefined(Main, :reservoir)
        @test Main.reservoir === Main.Reservoir
    end

    # ── AdEx ────────────────────────────────────────────────────────

    @testset "adex: constructor produces a usable reservoir" begin
        r = Main.Reservoir.adex(N = 16, seed = 1)
        @test length(r) == 16
        @test Main.Reservoir.steps_per_cycle(r) == 1000
        @test length(Main.Reservoir.spikes(r)) == 16
        @test !any(Main.Reservoir.spikes(r))   # nothing spiked yet
    end

    @testset "adex: input mismatch is a DimensionMismatch" begin
        r = Main.Reservoir.adex(N = 8, seed = 1)
        @test_throws DimensionMismatch Main.Reservoir.step!(r, zeros(7))
    end

    @testset "adex: strong drive eventually causes spikes" begin
        r = Main.Reservoir.adex(N = 16, seed = 2)
        input = fill(700.0, 16)   # strong current; well above rheobase
        any_spike = false
        for _ in 1:200
            Main.Reservoir.step!(r, input)
            if any(Main.Reservoir.spikes(r))
                any_spike = true
                break
            end
        end
        @test any_spike
    end

    @testset "adex: no drive ⇒ no spikes (rests at EL)" begin
        r = Main.Reservoir.adex(N = 16, seed = 3, p_connect = 0.0)
        input = zeros(16)
        for _ in 1:50
            Main.Reservoir.step!(r, input)
            @test !any(Main.Reservoir.spikes(r))
        end
    end

    @testset "adex: validates ctor args" begin
        @test_throws ArgumentError Main.Reservoir.adex(N = 0)
        @test_throws ArgumentError Main.Reservoir.adex(dt = -1.0)
        @test_throws ArgumentError Main.Reservoir.adex(p_connect = 2.0)
        @test_throws ArgumentError Main.Reservoir.adex(V_init = :weird)
    end

    # ── RECA ────────────────────────────────────────────────────────

    @testset "reca: constructor + single-cell seed" begin
        r = Main.Reservoir.reca(N = 16, rule = 30, init = :single)
        @test length(r) == 16
        @test count(Main.Reservoir.spikes(r)) == 1   # one seed cell
    end

    @testset "reca: rule 30 from single cell produces non-trivial growth" begin
        r = Main.Reservoir.reca(N = 32, rule = 30, init = :single)
        for _ in 1:10
            Main.Reservoir.step!(r, zeros(32))
        end
        # After 10 steps of rule 30 from a single cell, several cells
        # should be active and the pattern should be aperiodic.
        n_active = count(Main.Reservoir.spikes(r))
        @test 2 <= n_active <= 32
    end

    @testset "reca: rule 0 always dies (sanity check)" begin
        r = Main.Reservoir.reca(N = 8, rule = 0, init = :single)
        Main.Reservoir.step!(r, zeros(8))
        @test !any(Main.Reservoir.spikes(r))
    end

    @testset "reca: input XOR perturbs cells before stepping" begin
        r = Main.Reservoir.reca(N = 8, rule = 0, init = :zero)
        input = [1.0, 0, 0, 0, 0, 0, 0, 1.0]
        Main.Reservoir.step!(r, input)
        # Rule 0 turns everything off, so spikes() reflects post-rule
        # state (all off). The XOR happened; this just sanity-checks
        # that step! accepts the input shape.
        @test !any(Main.Reservoir.spikes(r))
    end

    @testset "reca: validates ctor args" begin
        @test_throws ArgumentError Main.Reservoir.reca(N = 0)
        @test_throws ArgumentError Main.Reservoir.reca(rule = 256)
        @test_throws ArgumentError Main.Reservoir.reca(rule = -1)
        @test_throws ArgumentError Main.Reservoir.reca(boundary = :weird)
        @test_throws ArgumentError Main.Reservoir.reca(init = :weird)
    end

    # ── Layouts ─────────────────────────────────────────────────────

    @testset "compute_layout :logfreq spreads N freqs log-uniformly" begin
        f = Main.Reservoir.compute_layout(:logfreq, 5, 100.0, 10000.0)
        @test length(f) == 5
        @test f[1] ≈ 100.0
        @test f[end] ≈ 10000.0
        # Log-uniform: consecutive ratios are equal.
        ratios = f[2:end] ./ f[1:end-1]
        @test all(r -> isapprox(r, ratios[1]; rtol = 1e-9), ratios)
    end

    @testset "compute_layout :scale quantises to scale degrees" begin
        f = Main.Reservoir.compute_layout(:scale, 5, 100.0, 10000.0;
                                          scale = :minor_pentatonic, root = 220.0)
        @test length(f) == 5
        @test f[1] ≈ 220.0
    end

    @testset "compute_layout :harmonic = i·fund" begin
        f = Main.Reservoir.compute_layout(:harmonic, 4, 100.0, 4000.0; fund = 110.0)
        @test f ≈ [110.0, 220.0, 330.0, 440.0]
    end

    @testset "compute_layout :cluster centers around `center`" begin
        f = Main.Reservoir.compute_layout(:cluster, 5, 100.0, 10000.0;
                                          center = 1000.0, spread = 0.1)
        @test 900.0 <= minimum(f)
        @test maximum(f) <= 1100.0
        @test 950.0 <= sum(f) / 5 <= 1050.0
    end

    @testset "compute_layout rejects unknown name" begin
        @test_throws ArgumentError Main.Reservoir.compute_layout(:nope, 4, 100, 4000)
    end

    # ── Route I — spike_burst ───────────────────────────────────────

    @testset "spike_burst returns a Pattern{ControlMap}" begin
        r = Main.Reservoir.adex(N = 8, steps_per_cycle = 100, seed = 4)
        p = Main.Reservoir.spike_burst(r; drive = 700.0)
        @test p isa Ressac.Pattern{Ressac.ControlMap}
    end

    @testset "spike_burst with strong drive produces events in a cycle" begin
        r = Main.Reservoir.adex(N = 8, steps_per_cycle = 200, seed = 5)
        p = Main.Reservoir.spike_burst(r; drive = 700.0, layout = :logfreq,
                                       lo = 200, hi = 4000)
        evs = p(0//1, 1//1)
        @test !isempty(evs)
        for ev in evs
            cm = ev.value
            @test cm[:s] === :sineburst
            @test 200.0 <= cm[:freq] <= 4000.0
            @test cm[:gain] ≈ 0.5
        end
    end

    @testset "spike_burst on RECA emits one event per active cell per step" begin
        r = Main.Reservoir.reca(N = 16, rule = 30, init = :single,
                                steps_per_cycle = 4)
        p = Main.Reservoir.spike_burst(r; layout = :scale,
                                       layout_args = (scale = :minor_pentatonic,))
        evs = p(0//1, 1//1)
        # Rule 30 from a single cell over 4 steps produces at least 2
        # active cells across all steps.
        @test length(evs) >= 2
    end

    @testset "spike_burst events are sorted by start time" begin
        r = Main.Reservoir.adex(N = 8, steps_per_cycle = 100, seed = 6)
        p = Main.Reservoir.spike_burst(r; drive = 700.0)
        evs = p(0//1, 2//1)
        starts = [ev.start for ev in evs]
        @test issorted(starts)
    end

    # ── Registry ────────────────────────────────────────────────────

    @testset "registry: list_reservoirs / list_layouts include built-ins" begin
        @test :adex in Main.Reservoir.list_reservoirs()
        @test :reca in Main.Reservoir.list_reservoirs()
        for layout in (:logfreq, :scale, :harmonic, :cluster)
            @test layout in Main.Reservoir.list_layouts()
        end
    end

    # ── Drive sources ───────────────────────────────────────────────

    @testset "drive::Real broadcasts to all neurons" begin
        buf = zeros(4)
        src = Main.Reservoir._make_drive_source(500.0, 4, 100)
        src(0, 1, buf)
        @test buf == fill(500.0, 4)
    end

    @testset "drive::Vector applies per-neuron" begin
        buf = zeros(4)
        src = Main.Reservoir._make_drive_source([100, 200, 300, 400], 4, 100)
        src(0, 1, buf)
        @test buf == [100.0, 200.0, 300.0, 400.0]
        # Mismatched length errors at construction.
        @test_throws DimensionMismatch Main.Reservoir._make_drive_source(
            [100, 200], 4, 100)
    end

    @testset "drive::Function called per step with cycle+step args" begin
        buf = zeros(3)
        f = (c, s) -> 100.0 * c + s
        src = Main.Reservoir._make_drive_source(f, 3, 50)
        src(2, 7, buf)
        @test buf == fill(207.0, 3)
    end

    @testset "drive::Function returning Vector dispatches per-neuron" begin
        buf = zeros(3)
        f = (c, s) -> [c, s, c + s]
        src = Main.Reservoir._make_drive_source(f, 3, 50)
        src(2, 7, buf)
        @test buf == [2.0, 7.0, 9.0]
    end

    @testset "drive::String auto-parses to a mini-notation pattern" begin
        # Bare string ≡ p"…" prefix — same downstream behavior.
        src = Main.Reservoir._make_drive_source("bd ~ sn ~", 8, 100)
        buf = zeros(8)
        src(0, 1, buf)
        @test sum(buf) > 0.0   # first event pulses
    end

    @testset "drive::Pattern{Symbol} pulses on event onsets" begin
        # `bd ~ sn ~` fires events at fractional onsets 0/4 and 2/4. With
        # spc=100 the step indices are 1 and 51. Each pulse sustains for
        # the default `_DRIVE_PULSE_STEPS=10` steps, then silence.
        p = Ressac.parse_minino("bd ~ sn ~")
        src = Main.Reservoir._make_drive_source(p, 8, 100)
        buf = zeros(8)
        src(0, 1, buf)
        @test sum(buf) > 0.0      # bd pulse active
        src(0, 30, buf)
        @test sum(buf) == 0.0     # silence between events (pulse over)
        src(0, 51, buf)
        @test sum(buf) > 0.0      # sn pulse active
    end

    @testset "drive::Pattern{Float64} broadcasts continuous value" begin
        # sine() emits one event per query at the midpoint sample.
        # For arc [0, 1) midpoint is 0.5 → sin(π) ≈ 0.
        src = Main.Reservoir._make_drive_source(sine(), 4, 8)
        buf = zeros(4)
        src(0, 1, buf)
        @test all(v -> isapprox(v, buf[1]; atol = 1e-9), buf)
    end

    # ── Drive helper functions ──────────────────────────────────────

    @testset "drive_const returns Real constant" begin
        f = Main.Reservoir.drive_const(500)
        @test f(0, 1) == 500.0
        @test f(42, 999) == 500.0
    end

    @testset "drive_sin oscillates between offset±amp" begin
        # period=100, amp=200, offset=400 → values in [200, 600]
        f = Main.Reservoir.drive_sin(200, 100; offset = 400)
        vals = [f(0, s) for s in 0:99]
        @test isapprox(minimum(vals), 200.0; atol = 1.0)
        @test isapprox(maximum(vals), 600.0; atol = 1.0)
        # Quarter-period (s=25) is the positive peak.
        @test f(0, 25) ≈ 600.0
    end

    @testset "drive_square: amp during duty fraction, offset otherwise" begin
        f = Main.Reservoir.drive_square(300, 100; duty = 0.3, offset = 50)
        @test f(0, 0) == 350.0    # high
        @test f(0, 29) == 350.0   # last step at high
        @test f(0, 30) == 50.0    # low starts
        @test f(0, 99) == 50.0    # still low
    end

    @testset "drive_ramp rises linearly from low to high" begin
        f = Main.Reservoir.drive_ramp(0, 100, 100)
        @test f(0, 0) ≈ 0.0
        @test f(0, 50) ≈ 50.0
        @test f(0, 99) ≈ 99.0
        # Reset at period boundary.
        @test f(0, 100) ≈ 0.0
    end

    @testset "drive_tri produces triangle between ±amp" begin
        f = Main.Reservoir.drive_tri(100, 100; offset = 0)
        @test f(0, 0) ≈ -100.0     # u=0
        @test f(0, 25) ≈ 0.0       # u=0.25, rising mid-zero crossing
        @test f(0, 50) ≈ 100.0     # u=0.5, peak
        @test f(0, 75) ≈ 0.0       # falling
    end

    @testset "drive_burst: on for on_steps within every_steps window" begin
        f = Main.Reservoir.drive_burst(500, 10, 100)
        @test f(0, 0) == 500.0     # in the on-window
        @test f(0, 9) == 500.0
        @test f(0, 10) == 0.0      # off
        @test f(0, 99) == 0.0
    end

    @testset "drive_sum composes drives additively" begin
        a = Main.Reservoir.drive_const(100)
        b = Main.Reservoir.drive_sin(50, 100; offset = 0)
        total = Main.Reservoir.drive_sum(a, b)
        # At s=25 (sine peak), total = 100 + 50 = 150
        @test isapprox(total(0, 25), 150.0; atol = 1.0)
        # At s=75 (sine trough), total = 100 - 50 = 50
        @test isapprox(total(0, 75), 50.0; atol = 1.0)
    end

    # ── OU noise ────────────────────────────────────────────────────

    @testset "AdEx with σ_noise=0 keeps V near EL when drive=0" begin
        # Without noise / drive / recurrence, V should stay close to
        # rest. The exponential term in the AdEx eq is non-zero even at
        # EL (it's the spike-slope upswing), so V drifts very slowly —
        # tolerate ≤0.01 mV after 50 ms of integration.
        r = Main.Reservoir.adex(N = 4, σ_noise = 0.0, p_connect = 0.0,
                                seed = 1)
        for _ in 1:50
            Main.Reservoir.step!(r, zeros(4))
        end
        @test all(v -> isapprox(v, r.params.EL; atol = 0.01), r.V)
    end

    @testset "AdEx with σ_noise>0 jitters V away from rest" begin
        r = Main.Reservoir.adex(N = 32, σ_noise = 100.0, p_connect = 0.0,
                                seed = 1)
        # Let noise build up.
        for _ in 1:500
            Main.Reservoir.step!(r, zeros(32))
        end
        var_V = sum((r.V .- r.params.EL) .^ 2) / 32
        @test var_V > 0.0
    end

    @testset "adex rejects bad noise / inhibition kwargs" begin
        @test_throws ArgumentError Main.Reservoir.adex(σ_noise = -1.0)
        @test_throws ArgumentError Main.Reservoir.adex(τ_noise = 0.0)
        @test_throws ArgumentError Main.Reservoir.adex(inhibitory_fraction = 1.5)
    end

    # ── Dale's principle ────────────────────────────────────────────

    @testset "inhibitory_fraction yields strictly-negative outgoing weights" begin
        r = Main.Reservoir.adex(N = 10, inhibitory_fraction = 0.3,
                                p_connect = 1.0, W_gain = 100.0, seed = 7)
        # Last 3 neurons should be inhibitory. Their outgoing column
        # (W[:, j]) must be ≤ 0 (with 0 for the diagonal entry).
        inhib_idx = findall(r.inhib)
        @test length(inhib_idx) == 3
        for j in inhib_idx
            outgoing = [r.W[i, j] for i in 1:r.N if i != j]
            @test all(w -> w <= 0, outgoing)
        end
        # Excitatory column ≥ 0.
        excit_idx = findall(.!r.inhib)
        for j in excit_idx
            outgoing = [r.W[i, j] for i in 1:r.N if i != j]
            @test all(w -> w >= 0, outgoing)
        end
    end

    # ── Route III — modulator ───────────────────────────────────────

    @testset "modulator returns a Pattern{Float64}" begin
        r = Main.Reservoir.adex(N = 8, seed = 10)
        m = Main.Reservoir.modulator(r)
        @test m isa Ressac.Pattern{Float64}
    end

    @testset "modulator emits one event per query covering the arc" begin
        r = Main.Reservoir.adex(N = 8, seed = 11)
        m = Main.Reservoir.modulator(r, neuron = 1, drive = 600.0)
        evs = m(0//1, 1//1)
        @test length(evs) == 1
        @test evs[1].start == 0//1
        @test evs[1].stop == 1//1
        @test isfinite(evs[1].value)
    end

    @testset "modulator: AdEx :V resting near EL (-70.6 mV) with no drive" begin
        # `scale=identity` opts out of the :auto normaliser so we can
        # assert on the raw mV reading.
        r = Main.Reservoir.adex(N = 4, seed = 12, p_connect = 0.0)
        m = Main.Reservoir.modulator(r, neuron = 1, kind = :V,
                                     scale = identity, drive = 0.0)
        evs = m(0//1, 1//1)
        @test -71.0 <= evs[1].value <= -70.0
    end

    @testset "modulator: AdEx :V leaves rest under strong drive (raw mV)" begin
        # Same opt-out — checks the underlying integrator is advancing.
        r = Main.Reservoir.adex(N = 4, seed = 13)
        m = Main.Reservoir.modulator(r, neuron = 1, kind = :V,
                                     scale = identity, drive = 600.0)
        v = m(0//1, 1//1)[1].value
        @test v > -65.0
    end

    @testset "modulator: scale=:auto maps AdEx :V into [-1, 1]" begin
        r = Main.Reservoir.adex(N = 4, seed = 14)
        m = Main.Reservoir.modulator(r, neuron = 1, kind = :V, drive = 600.0)
        v = m(0//1, 1//1)[1].value
        @test -1.0 <= v <= 1.0
    end

    @testset "modulator: RECA :bit raw returns 0/1, :auto returns ±1" begin
        r1 = Main.Reservoir.reca(N = 16, rule = 30, init = :single)
        v_raw = Main.Reservoir.modulator(r1, neuron = 8,
                                          scale = identity)(0//1, 1//1)[1].value
        @test v_raw in (0.0, 1.0)
        r2 = Main.Reservoir.reca(N = 16, rule = 30, init = :single)
        v_auto = Main.Reservoir.modulator(r2, neuron = 8)(0//1, 1//1)[1].value
        @test v_auto in (-1.0, 1.0)
    end

    @testset "modulator: scale function is applied" begin
        r = Main.Reservoir.adex(N = 4, seed = 14, p_connect = 0.0)
        m = Main.Reservoir.modulator(r, neuron = 1, kind = :V,
                                     scale = v -> v + 100.0)
        v = m(0//1, 1//1)[1].value
        @test 29.0 <= v <= 30.0   # rest ≈ -70.6, scale adds 100
    end

    @testset "modulator: composes with range_pat" begin
        r = Main.Reservoir.reca(N = 16, rule = 30, init = :single,
                                steps_per_cycle = 4)
        # RECA :bit is in {0, 1}; range_pat treats positives as already-
        # unipolar (range [0, 1] → [lo, hi]).
        m = Main.Reservoir.modulator(r, neuron = 8) |> range_pat(200.0, 4000.0)
        for c in 0:5
            v = m(Rational(c), Rational(c + 1))[1].value
            @test 200.0 <= v <= 4000.0
        end
    end

    @testset "modulator: rejects bad neuron index up-front" begin
        r = Main.Reservoir.adex(N = 4, seed = 15)
        @test_throws BoundsError Main.Reservoir.modulator(r, neuron = 5)
        @test_throws BoundsError Main.Reservoir.modulator(r, neuron = 0)
    end

    @testset "modulator: rejects unknown kind up-front" begin
        r = Main.Reservoir.adex(N = 4, seed = 16)
        @test_throws ArgumentError Main.Reservoir.modulator(r, kind = :nope)
    end

    @testset "modulator: kind=:density returns fraction (raw) / ±1 (:auto)" begin
        r1 = Main.Reservoir.reca(N = 16, rule = 30, init = :single,
                                  steps_per_cycle = 4)
        v_raw = Main.Reservoir.modulator(r1, kind = :density,
                                          scale = identity)(0//1, 1//1)[1].value
        @test 0.0 <= v_raw <= 1.0
        r2 = Main.Reservoir.reca(N = 16, rule = 30, init = :single,
                                  steps_per_cycle = 4)
        v_auto = Main.Reservoir.modulator(r2, kind = :density)(0//1, 1//1)[1].value
        @test -1.0 <= v_auto <= 1.0
    end

    # ── Route II — spectral cloud ───────────────────────────────────

    @testset "spectral_cloud returns a Pattern{ControlMap}" begin
        r = Main.Reservoir.adex(N = 16, seed = 20)
        p = Main.Reservoir.spectral_cloud(r)
        @test p isa Ressac.Pattern{Ressac.ControlMap}
    end

    @testset "spectral_cloud fires frames_per_cycle events per cycle" begin
        r = Main.Reservoir.adex(N = 16, steps_per_cycle = 200, seed = 21)
        p = Main.Reservoir.spectral_cloud(r; frames_per_cycle = 4,
                                          drive = 600.0)
        evs = p(0//1, 1//1)
        @test length(evs) == 4
    end

    @testset "spectral_cloud each event carries 16 freq + 16 amp keys" begin
        r = Main.Reservoir.reca(N = 16, rule = 30, init = :rand, seed = 22)
        p = Main.Reservoir.spectral_cloud(r; frames_per_cycle = 2)
        evs = p(0//1, 1//1)
        @test !isempty(evs)
        cm = evs[1].value
        @test cm[:s] === :specloud16
        for i in 1:16
            @test haskey(cm, Symbol("freq_$i"))
            @test haskey(cm, Symbol("amp_$i"))
        end
    end

    @testset "spectral_cloud freqs follow the chosen layout" begin
        r = Main.Reservoir.reca(N = 16, rule = 30, init = :rand, seed = 23)
        p = Main.Reservoir.spectral_cloud(r; frames_per_cycle = 2,
                                          layout = :logfreq,
                                          lo = 100, hi = 10_000)
        cm = p(0//1, 1//1)[1].value
        @test cm[Symbol("freq_1")] ≈ 100.0
        @test cm[Symbol("freq_16")] ≈ 10_000.0
    end

    @testset "spectral_cloud AdEx :V amps are clipped to [0, 1] by default scale" begin
        r = Main.Reservoir.adex(N = 16, seed = 24, p_connect = 0.0)
        p = Main.Reservoir.spectral_cloud(r; frames_per_cycle = 2, drive = 0.0)
        cm = p(0//1, 1//1)[1].value
        for i in 1:16
            @test 0.0 <= cm[Symbol("amp_$i")] <= 1.0
        end
    end

    @testset "spectral_cloud RECA :bit amps are 0 or 1" begin
        r = Main.Reservoir.reca(N = 16, rule = 30, init = :single)
        p = Main.Reservoir.spectral_cloud(r; frames_per_cycle = 4)
        evs = p(0//1, 1//1)
        for ev in evs
            cm = ev.value
            for i in 1:16
                @test cm[Symbol("amp_$i")] in (0.0, 1.0)
            end
        end
    end

    @testset "spectral_cloud sustain reflects overlap" begin
        r = Main.Reservoir.reca(N = 16, rule = 30)
        p1 = Main.Reservoir.spectral_cloud(r; frames_per_cycle = 8, overlap = 1.0)
        cm1 = p1(0//1, 1//1)[1].value
        @test cm1[:sustain] ≈ 1.0 / 8

        r2 = Main.Reservoir.reca(N = 16, rule = 30)
        p2 = Main.Reservoir.spectral_cloud(r2; frames_per_cycle = 8, overlap = 2.0)
        cm2 = p2(0//1, 1//1)[1].value
        @test cm2[:sustain] ≈ 2.0 / 8
    end

    @testset "spectral_cloud rejects bins > length(r)" begin
        r = Main.Reservoir.reca(N = 8, rule = 30)
        @test_throws ArgumentError Main.Reservoir.spectral_cloud(r; bins = 16)
    end

    @testset "spectral_cloud rejects invalid frames_per_cycle / bins" begin
        r = Main.Reservoir.reca(N = 16, rule = 30)
        @test_throws ArgumentError Main.Reservoir.spectral_cloud(r; frames_per_cycle = 0)
        @test_throws ArgumentError Main.Reservoir.spectral_cloud(r; bins = 0)
    end

    @testset "spectral_cloud events are sorted by start" begin
        r = Main.Reservoir.adex(N = 16, seed = 25)
        p = Main.Reservoir.spectral_cloud(r; frames_per_cycle = 8, drive = 600.0)
        evs = p(0//1, 2//1)
        @test issorted([ev.start for ev in evs])
        @test length(evs) == 16
    end

    # ── Route IV — tonal pool ───────────────────────────────────────

    @testset "pool_burst returns a Pattern{ControlMap}" begin
        r = Main.Reservoir.adex(N = 16, σ_noise = 300.0, seed = 30)
        p = Main.Reservoir.pool_burst(r; bins = 8, drive = 500.0)
        @test p isa Ressac.Pattern{Ressac.ControlMap}
    end

    @testset "pool_burst events share K distinct freqs (the bins)" begin
        r = Main.Reservoir.adex(N = 24, σ_noise = 400.0, seed = 31)
        p = Main.Reservoir.pool_burst(r; bins = 8, frames_per_cycle = 8,
                                       drive = 500.0)
        evs = p(0//1, 1//1)
        @test !isempty(evs)
        freqs = unique(ev.value[:freq] for ev in evs)
        @test length(freqs) <= 8
    end

    @testset "pool_burst gain scales with spike count" begin
        # Strong drive → multiple spikes per bin per frame → gain > per_spike.
        r = Main.Reservoir.adex(N = 24, σ_noise = 400.0, seed = 32)
        p = Main.Reservoir.pool_burst(r; bins = 6, frames_per_cycle = 4,
                                       drive = 600.0, gain_per_spike = 0.1)
        evs = p(0//1, 1//1)
        @test any(ev -> ev.value[:gain] > 0.1, evs)   # at least one bin had ≥2 spikes
    end

    @testset "pool_burst gain clamped to max_gain" begin
        r = Main.Reservoir.adex(N = 64, σ_noise = 500.0, seed = 33)
        p = Main.Reservoir.pool_burst(r; bins = 4, frames_per_cycle = 2,
                                       drive = 700.0, gain_per_spike = 0.5,
                                       max_gain = 0.6)
        evs = p(0//1, 1//1)
        @test all(ev -> ev.value[:gain] <= 0.6 + 1e-9, evs)
    end

    @testset "pool_burst rejects invalid kwargs" begin
        r = Main.Reservoir.adex(N = 16, seed = 34)
        @test_throws ArgumentError Main.Reservoir.pool_burst(r; bins = 0)
        @test_throws ArgumentError Main.Reservoir.pool_burst(r;
                                                              frames_per_cycle = 0)
        @test_throws ArgumentError Main.Reservoir.pool_burst(r; mapping = :weird)
    end

    @testset "pool_burst :hash mapping spreads neurons differently" begin
        r1 = Main.Reservoir.adex(N = 24, σ_noise = 400.0, seed = 35)
        r2 = Main.Reservoir.adex(N = 24, σ_noise = 400.0, seed = 35)
        e1 = Main.Reservoir.pool_burst(r1; bins = 6, mapping = :roundrobin,
                                        drive = 500.0)(0//1, 1//1)
        e2 = Main.Reservoir.pool_burst(r2; bins = 6, mapping = :hash,
                                        drive = 500.0)(0//1, 1//1)
        # Different mapping → at least one frame's bin gains differ.
        @test [ev.value[:gain] for ev in e1] != [ev.value[:gain] for ev in e2]
    end

    # ── Audio-in drive ──────────────────────────────────────────────

    @testset "drive=:audio_in broadcasts the latest RMS to all neurons" begin
        Ressac._AUDIO_IN_VALUE[] = 0.5
        src = Main.Reservoir._make_drive_source(:audio_in, 4, 100)
        buf = zeros(4)
        src(0, 1, buf)
        @test all(v -> isapprox(v, 0.5 * 1500.0; atol = 1e-9), buf)
        # Update the global → next call reads the new value.
        Ressac._AUDIO_IN_VALUE[] = 0.1
        src(0, 2, buf)
        @test all(v -> isapprox(v, 0.1 * 1500.0; atol = 1e-9), buf)
        Ressac._AUDIO_IN_VALUE[] = 0.0
    end

    @testset "drive=:audio_in rejects other symbol names" begin
        @test_throws ArgumentError Main.Reservoir._make_drive_source(
            :unknown_input, 4, 100)
    end

    @testset "_handle_audio_in! clamps to [0, 1]" begin
        Ressac._handle_audio_in!(Any[Float32(0.7)])
        @test Ressac._AUDIO_IN_VALUE[] ≈ 0.7f0    # Float32→Float64 noise
        Ressac._handle_audio_in!(Any[Float32(2.0)])
        @test Ressac._AUDIO_IN_VALUE[] == 1.0      # clamped to ceiling
        Ressac._handle_audio_in!(Any[Float32(-0.5)])
        @test Ressac._AUDIO_IN_VALUE[] == 0.0      # clamped to floor
        Ressac._AUDIO_IN_VALUE[] = 0.0
    end

    # ── History recording for the visual scope ──────────────────────

    @testset "record_history! off by default (zero overhead)" begin
        r = Main.Reservoir.adex(N = 8, seed = 200)
        @test r.record_capacity == 0
        Main.Reservoir.step!(r, zeros(8))
        @test isempty(r.history)
    end

    @testset "record_history! captures spike_buf snapshots" begin
        r = Main.Reservoir.adex(N = 8, σ_noise = 0, p_connect = 0,
                                seed = 201)
        Main.Reservoir.record_history!(r, 20)
        for _ in 1:30
            Main.Reservoir.step!(r, fill(700.0, 8))
        end
        @test length(r.history) == 20   # capped at the ring size
        @test all(snap -> length(snap) == 8, r.history)
    end

    @testset "record_history!(r, 0) stops + drains" begin
        r = Main.Reservoir.adex(N = 4, seed = 202)
        Main.Reservoir.record_history!(r, 10)
        for _ in 1:5
            Main.Reservoir.step!(r, fill(700.0, 4))
        end
        @test !isempty(r.history)
        Main.Reservoir.record_history!(r, 0)
        @test isempty(r.history)
        @test r.record_capacity == 0
    end

    @testset "record_history! works on RECA too" begin
        r = Main.Reservoir.reca(N = 8, rule = 30, init = :rand, seed = 203)
        Main.Reservoir.record_history!(r, 15)
        for _ in 1:20
            Main.Reservoir.step!(r, zeros(8))
        end
        @test length(r.history) == 15
        @test all(snap -> length(snap) == 8, r.history)
    end

    # ── Coupled reservoirs (E/I populations) ────────────────────────

    @testset "couple() + connect! builds a group with projections" begin
        r1 = Main.Reservoir.adex(N = 8, seed = 100)
        r2 = Main.Reservoir.adex(N = 4, seed = 101)
        g = Main.Reservoir.couple([r1, r2]; output_idx = 1)
        @test length(g.members) == 2
        @test isempty(g.couplings)
        Main.Reservoir.connect!(g, 1, 2; gain = 200, p_connect = 0.5,
                                 sign = :positive, seed = 0)
        @test length(g.couplings) == 1
        src, dst, W = g.couplings[1]
        @test (src, dst) == (1, 2)
        @test size(W) == (4, 8)
        @test all(W .>= 0)
    end

    @testset "couple() :negative sign produces ≤ 0 weights" begin
        r1 = Main.Reservoir.adex(N = 8, seed = 102)
        r2 = Main.Reservoir.adex(N = 4, seed = 103)
        g = Main.Reservoir.couple([r1, r2])
        Main.Reservoir.connect!(g, 1, 2; gain = 200, p_connect = 1.0,
                                 sign = :negative, seed = 0)
        @test all(g.couplings[1][3] .<= 0)
    end

    @testset "CoupledReservoirs implements the interface contract" begin
        r1 = Main.Reservoir.adex(N = 8, seed = 110)
        r2 = Main.Reservoir.adex(N = 4, seed = 111)
        g = Main.Reservoir.couple([r1, r2]; output_idx = 1)
        @test length(g) == 8
        @test Main.Reservoir.steps_per_cycle(g) == Main.Reservoir.steps_per_cycle(r1)
        @test length(Main.Reservoir.spikes(g)) == 8
        @test Main.Reservoir.read_state(g, :V, 1) isa Real
    end

    @testset "step!(group) advances every member in lockstep" begin
        r1 = Main.Reservoir.adex(N = 8, σ_noise = 0.0, seed = 120, p_connect = 0.0)
        r2 = Main.Reservoir.adex(N = 4, σ_noise = 0.0, seed = 121, p_connect = 0.0)
        g = Main.Reservoir.couple([r1, r2]; output_idx = 1)
        Main.Reservoir.connect!(g, 1, 2; gain = 600, p_connect = 1.0,
                                 sign = :positive, seed = 0)
        for _ in 1:30
            Main.Reservoir.step!(g, fill(700.0, 8))
        end
        @test any(v -> v > r2.params.EL + 0.1, r2.V)
    end

    @testset "step!(group) input length must match output member" begin
        r1 = Main.Reservoir.adex(N = 8, seed = 130)
        r2 = Main.Reservoir.adex(N = 4, seed = 131)
        g = Main.Reservoir.couple([r1, r2]; output_idx = 1)
        @test_throws DimensionMismatch Main.Reservoir.step!(g, zeros(7))
    end

    @testset "spike_burst on a group emits events from the output member" begin
        r_E = Main.Reservoir.adex(N = 16, σ_noise = 400.0, seed = 140)
        r_I = Main.Reservoir.adex(N = 4,  σ_noise = 300.0, seed = 141)
        g = Main.Reservoir.couple([r_E, r_I]; output_idx = 1)
        Main.Reservoir.connect!(g, 1, 2; gain = 200, p_connect = 0.3,
                                 sign = :positive, seed = 0)
        Main.Reservoir.connect!(g, 2, 1; gain = 200, p_connect = 0.3,
                                 sign = :negative, seed = 0)
        p = Main.Reservoir.spike_burst(g; drive = 500.0)
        evs = p(0//1, 1//1)
        @test !isempty(evs)
        @test all(ev -> 200.0 <= ev.value[:freq] <= 4000.0, evs)
    end

    @testset "couple/connect! reject invalid args" begin
        r1 = Main.Reservoir.adex(N = 4, seed = 150)
        @test_throws ArgumentError Main.Reservoir.couple([]; output_idx = 1)
        @test_throws ArgumentError Main.Reservoir.couple([r1]; output_idx = 5)
        g = Main.Reservoir.couple([r1])
        @test_throws ArgumentError Main.Reservoir.connect!(g, 0, 1;
                                                            gain = 1, p_connect = 0.1)
        @test_throws ArgumentError Main.Reservoir.connect!(g, 1, 1;
                                                            sign = :weird,
                                                            gain = 1, p_connect = 0.1)
    end

    # ── End-to-end OSC routing — sineburst from spike_burst ─────────
    # Verifies the full path WITHOUT scsynth running: Reservoir →
    # Pattern{ControlMap} → event_to_osc → OSCMessage to /dirt/play
    # with s="sineburst" + freq/gain/sustain args. If any of this is
    # wrong, the synth is silent in live mode.

    @testset "Route I → /dirt/play s sineburst (no audio needed)" begin
        plugin_dir = joinpath(@__DIR__, "..", "plugins", "reservoir")

        @testset "sineburst.scd exists and declares the SynthDef" begin
            path = joinpath(plugin_dir, "sineburst.scd")
            @test isfile(path)
            body = read(path, String)
            @test occursin("SynthDef(\\sineburst", body)
            @test occursin("DirtPan.ar", body)   # SuperDirt convention
        end

        @testset "plugin.toml lists sineburst.scd under [synthdefs]" begin
            # TOML is a Julia stdlib loaded transitively via Ressac.
            import TOML
            toml = TOML.parsefile(joinpath(plugin_dir, "plugin.toml"))
            @test "sineburst.scd" in
                  map(basename, get(toml["synthdefs"], "files", String[]))
        end

        @testset "spike_burst events encode to /dirt/play s sineburst" begin
            r = Main.Reservoir.adex(N = 4, steps_per_cycle = 50, seed = 100)
            p = Main.Reservoir.spike_burst(r; drive = 700.0,
                                           layout = :logfreq,
                                           lo = 200, hi = 4000)
            evs = p(0//1, 1//1)
            @test !isempty(evs)

            ev = evs[1]
            osc = Ressac.event_to_osc(ev)
            @test osc isa Ressac.OSCMessage
            @test osc.address == "/dirt/play"
            # Args are flat ["s", "sineburst", "freq", 200.0, ...] etc.
            kv = Dict(string(osc.args[i]) => osc.args[i + 1]
                      for i in 1:2:length(osc.args))
            @test kv["s"] == "sineburst"
            @test 200.0 <= kv["freq"] <= 4000.0
            @test kv["gain"] ≈ Float32(0.5)
            @test 0 < kv["sustain"]
        end

        @testset "encoded OSC bytes parse as a well-formed message" begin
            r = Main.Reservoir.adex(N = 4, steps_per_cycle = 50, seed = 101)
            ev = first(Main.Reservoir.spike_burst(r; drive = 700.0)(0//1, 1//1))
            bytes = Ressac.encode(Ressac.event_to_osc(ev))
            @test bytes isa Vector{UInt8}
            @test length(bytes) % 4 == 0      # OSC requires 4-byte alignment
            # Address comes first, null-terminated and 4-byte padded.
            addr_end = findfirst(==(0x00), bytes)
            @test addr_end !== nothing
            @test String(bytes[1:addr_end - 1]) == "/dirt/play"
        end
    end

    @testset "registry: register_reservoir! / register_layout! add entries" begin
        ctor = (; kwargs...) -> Main.Reservoir.adex(; kwargs...)
        Main.Reservoir.register_reservoir!(:my_kind, ctor)
        @test :my_kind in Main.Reservoir.list_reservoirs()

        my_layout = (N, lo, hi; kwargs...) -> fill(440.0, N)
        Main.Reservoir.register_layout!(:flat, my_layout)
        @test :flat in Main.Reservoir.list_layouts()
        @test Main.Reservoir.compute_layout(:flat, 3, 0, 0) ≈ fill(440.0, 3)
    end
end
