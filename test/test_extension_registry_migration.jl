using Test
using Ressac

# Échantillons figés des docs de plugins (en français depuis 2026-09-21).
# This is a smoke check, not exhaustive: 10 representative doc entries
# and 3 starters spanning every routing bucket (core, reservoir, chaos).
# Goal: catch a regression where a routing rule silently dropped content.

const _MIGRATION_SAMPLE_DOCS = Dict{String,String}(
    "gain" => "Multiplicateur de volume. 1 = neutre, 0.5 = moitié, 2 = double. Se compose en ×.",
    "cps" => "Cycles par seconde — l'unité de tempo de Ressac. 0.5 = 1 cycle / 2 s (30 BPM à 4 temps/cycle), 0.8 ≈ 48 BPM, 0.3 = 18 BPM. cps!(x) le règle en live, :cps x depuis la TUI.",
    "n" => "Décalage de note (demi-tons) pour un synth, ou index de variante pour une banque de samples.",
    "fast" => "fast(n, p) ou `p |> fast(n)` — compresse le temps ×n. fast(2) joue deux fois par cycle.",
    "Reservoir.adex" => "Construit un réservoir de neurones AdEx. kwargs : N, params=ADEX_*, σ_noise (bruit OU en pA), τ_noise (ms), inhibitory_fraction, p_connect, W_gain, V_init=:rest|:scattered, seed.",
    "Reservoir.spike_burst" => "Route I — chaque impulsion tire une bouffée de sinus à la fréquence du neurone. kwargs : drive, layout, layout_args, lo, hi, burst_dur, gain, synth.",
    "drive_const" => "drive_const(amp) → Function. Courant constant sur tous les neurones à chaque pas.",
    "ADEX_TONIC" => "Préréglage AdEx — décharge tonique (régulière, sans adaptation).",
    "lorenz" => "UGen LorenzL au taux AUDIO pour @synth (sc3-plugins). Args : freq, σ, ρ, β, h, xi, yi, zi. Au taux de contrôle : Chaos.lorenz.",
    "henon" => "UGen HenonL au taux AUDIO pour @synth. Args : freq, a, b, x0, x1. Au taux de contrôle : Chaos.henon.",
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
