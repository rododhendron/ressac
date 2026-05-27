# ╭─ Winner-takes-all — séquence mono d'un seul neurone à la fois ─╮
# │  Mêmes neurones AdEx, mêmes dynamiques, mais 1 spike max
# │  reported par step → mélodie monophonique au lieu d'accords
# │  empilés. Le 'gagnant' = celui avec V le plus haut just
# │  avant reset.
# ╰────────────────────────────────────────────────────────────────╯
cps!(0.5)

r = Reservoir.adex(N=12, params=Reservoir.ADEX_REGULAR_BURST,
                   σ_noise=400.0, wta=true, seed=42)

@d1 Reservoir.spike_burst(r;
    drive=500.0,
    layout=:scale, layout_args=(scale=:minor_pentatonic, root=220),
    burst_dur=1//8) |> gain(0.5)

@d9 p"bd ~ ~ ~ bd ~ ~ ~" |> gain(1.2)