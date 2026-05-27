using Test
using Ressac

# Frozen samples from pre-migration _PARAM_DOCS / _STARTER_PACKS.
# This is a smoke check, not exhaustive: 10 representative doc entries
# and 3 starters spanning every routing bucket (core, reservoir, chaos).
# Goal: catch a regression where a routing rule silently dropped content.

const _MIGRATION_SAMPLE_DOCS = Dict{String,String}(
    "gain" => "Volume multiplier. 1=neutral, 0.5=half, 2=double. Composes ×.",
    "cps" => "Cycles per second — Ressac's tempo unit. 0.5 = 1 cycle / 2s (30 BPM @ 4 beats/cycle), 0.8 = ~48 BPM, 0.3 = 18 BPM. cps!(x) sets it live, :cps x is the TUI form.",
    "n" => "Note offset (semitones) for synths, or sample-variant index for sample banks.",
    "fast" => "fast(n, p) or `p |> fast(n)` — compress time ×n. fast(2) plays twice in a cycle.",
    "Reservoir.adex" => "Build an AdEx spiking-neuron reservoir. kwargs: N, params=ADEX_*, σ_noise (OU noise pA), τ_noise (ms), inhibitory_fraction, p_connect, W_gain, V_init=:rest|:scattered, seed.",
    "Reservoir.spike_burst" => "Route I — each spike fires a sineburst event at the neuron's mapped freq. kwargs: drive, layout, layout_args, lo, hi, burst_dur, gain, synth.",
    "drive_const" => "drive_const(amp) → Function. Constant current to all neurons each step.",
    "ADEX_TONIC" => "AdEx preset — tonic spiking (steady firing, no adaptation).",
    "lorenz" => "AUDIO-rate LorenzL UGen for @synth (sc3-plugins). Args: freq, σ, ρ, β, h, xi, yi, zi. For control-rate use Chaos.lorenz.",
    "henon" => "AUDIO-rate HenonL UGen for @synth. Args: freq, a, b, x0, x1. For control-rate use Chaos.henon.",
)

const _MIGRATION_SAMPLE_STARTERS = ["dub-techno", "reservoir-pop5", "chaos-explore"]

@testset "migration round-trip" begin
    @testset "every sampled doc resolves via lookup_doc" begin
        for (name, expected_short) in _MIGRATION_SAMPLE_DOCS
            e = Ressac.lookup_doc(name)
            @test e !== nothing
            if e !== nothing
                @test e.short == expected_short
            end
        end
    end

    @testset "every sampled starter resolves via lookup_snippet" begin
        for name in _MIGRATION_SAMPLE_STARTERS
            snip = Ressac.lookup_snippet(name)
            @test snip !== nothing
            if snip !== nothing
                @test snip.mode === :starter
                @test !isempty(snip.resolved_content)
            end
        end
    end
end
