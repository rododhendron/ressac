using Test
using Ressac

# Échantillons figés des docs de plugins (en anglais depuis 2026-10-01).
# This is a smoke check, not exhaustive: 10 representative doc entries
# and 3 starters spanning every routing bucket (core, reservoir, chaos).
# Goal: catch a regression where a routing rule silently dropped content.

const _MIGRATION_SAMPLE_DOCS = Dict{String,String}(
    "gain" => "Volume multiplier. 1 = unity, 0.5 = half, 2 = double. Composes by ×.",
    "cps" => "Cycles per second — Ressac's tempo unit. 0.5 = 1 cycle / 2 s (30 BPM at 4 beats per cycle), 0.8 ≈ 48 BPM, 0.3 = 18 BPM. cps!(x) sets it live, :cps x from the TUI.",
    "n" => "Note offset (semitones) for a synth, or variant index for a sample bank.",
    "fast" => "fast(n, p) or `p |> fast(n)` — compresses time ×n. fast(2) plays twice per cycle.",
    "Reservoir.adex" => "Builds a reservoir of AdEx neurons. kwargs: N, params=ADEX_*, σ_noise (OU noise in pA), τ_noise (ms), inhibitory_fraction, p_connect, W_gain, V_init=:rest|:scattered, seed.",
    "Reservoir.spike_burst" => "Route I — every spike fires a burst of sine at the neuron's frequency. kwargs: drive, layout, layout_args, lo, hi, burst_dur, gain, synth.",
    "drive_const" => "drive_const(amp) → Function. Constant current on every neuron at every step.",
    "ADEX_TONIC" => "AdEx preset — tonic firing (regular, no adaptation).",
    "lorenz" => "LorenzL UGen at AUDIO rate for @synth (sc3-plugins). Args: freq, σ, ρ, β, h, xi, yi, zi. At control rate: Chaos.lorenz.",
    "henon" => "HenonL UGen at AUDIO rate for @synth. Args: freq, a, b, x0, x1. At control rate: Chaos.henon.",
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
