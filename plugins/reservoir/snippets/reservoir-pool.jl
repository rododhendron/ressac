# ╭─ tonal pool — neurones votent pour des notes ─╮
# │  N neurones → K tons. Multiple spikes sur le même
# │  bin → gain accumulé. Fluctuations de tonalité
# │  + volume par ton émergent du réseau.
# ╰─────────────────────────────────────────────────╯
cps!(0.5)

# AdEx bursting + noise → activité riche pour alimenter le pool
r = Reservoir.adex(N=32, params=Reservoir.ADEX_BURSTING,
                   σ_noise=400.0, seed=42)

# 8 bins pentatoniques mineurs depuis 110 Hz. frames_per_cycle=8
# donne une nouvelle 'voix' (gain accumulé) tous les 1/8 de cycle.
@d1 Reservoir.pool_burst(r;
    bins=8,
    frames_per_cycle=8,
    layout=:scale, layout_args=(scale=:minor_pentatonic, root=110),
    drive=500.0,
    gain_per_spike=0.06,
    max_gain=0.7,
    burst_dur=1//16) |> gain(0.5)

# Anchor
@d9 p"bd ~ ~ ~ bd ~ ~ ~" |> gain(1.2)