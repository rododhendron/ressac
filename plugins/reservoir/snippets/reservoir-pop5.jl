# ╭─ 5 populations interconnectées qui se répondent ─╮
# │  5 sous-réservoirs aux paramètres différents (donc
# │  fréquences propres différentes) couplés en boucle.
# │  Chaque pop devient une voix avec sa freq émergente.
# │  Si les couplages déstabilisent → polyphonie qui
# │  évolue. Si trop forts → tout sync sur une fréquence.
# ╰────────────────────────────────────────────────────╯
cps!(0.5)

# Cinq pops, chacune avec son régime AdEx + son seed.
# steps_per_cycle=2000 partout → cohérence du couplage.
p_A = Reservoir.adex(N=12, params=Reservoir.ADEX_TONIC,
                     dt=1.0, steps_per_cycle=800,
                     σ_noise=400.0, seed=1)
p_B = Reservoir.adex(N=12, params=Reservoir.ADEX_ADAPTING,
                     dt=1.0, steps_per_cycle=800,
                     σ_noise=350.0, seed=2)
p_C = Reservoir.adex(N=12, params=Reservoir.ADEX_REGULAR_BURST,
                     dt=1.0, steps_per_cycle=800,
                     σ_noise=300.0, seed=3)
p_D = Reservoir.adex(N=12, params=Reservoir.ADEX_FAST,
                     dt=1.0, steps_per_cycle=800,
                     σ_noise=450.0, seed=4)
p_E = Reservoir.adex(N=12, params=Reservoir.ADEX_IRREGULAR,
                     dt=1.0, steps_per_cycle=800,
                     σ_noise=380.0, seed=5)

# Couplage en anneau A→B→C→D→E→A, plus deux raccourcis
# pour casser la symétrie (A→C inhibitrice, D→A excitatrice).
g = Reservoir.couple([p_A, p_B, p_C, p_D, p_E]; output_idx=1)
Reservoir.connect!(g, 1, 2; gain=180, p_connect=0.25, sign=:positive)
Reservoir.connect!(g, 2, 3; gain=180, p_connect=0.25, sign=:positive)
Reservoir.connect!(g, 3, 4; gain=180, p_connect=0.25, sign=:positive)
Reservoir.connect!(g, 4, 5; gain=180, p_connect=0.25, sign=:positive)
Reservoir.connect!(g, 5, 1; gain=200, p_connect=0.25, sign=:positive)
Reservoir.connect!(g, 1, 3; gain=150, p_connect=0.20, sign=:negative)
Reservoir.connect!(g, 4, 1; gain=120, p_connect=0.20, sign=:positive)

# Une voix rate_voice par population. Chaque pop = un groupe de neurones
# (indices DANS LE GROUPE COUPLÉ → 1..12 pour A, 13..24 pour B, …).
@d1 Reservoir.rate_voice(g;
    sources=[collect(1:12), collect(13:24), collect(25:36),
             collect(37:48), collect(49:60)],
    shape=:saw,
    frames_per_cycle=16,
    freq_scale=1.5, freq_offset=60.0,
    lo_freq=55.0, hi_freq=1600.0,
    gain=0.12, overlap=2.5,
    smoothing_frames=3,
    drive=Reservoir.drive_const(280.0)) |> gain(0.7)

# Anchor
@d9 p"bd ~ ~ ~ bd ~ ~ ~" |> gain(1.0)

# Live tweaks : change σ_noise d'une pop pour pousser sa freq.
# Change le gain d'une connect! → bascule lock-in / chaos.
# Visualise avec :scope reservoir-graph (montre les 5 pops + edges).