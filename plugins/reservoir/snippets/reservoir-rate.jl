# ╭─ Route V — spike rate AS frequency ─╮
# │  On compte les spikes par neurone et par frame, on
# │  convertit en Hz, et on commande un oscillateur avec.
# │  Si un neurone spike à 200 Hz → tu entends 200 Hz.
# │  4 shapes : :impulse (clic brut), :saw, :sin, :pulse.
# ╰───────────────────────────────────────╯
cps!(0.5)

# Reservoir actif avec du bruit pour qu'il spike fort.
# steps_per_cycle=2000 → résolution temporelle fine (1ms à 0.5cps),
# nécessaire pour capter des taux jusqu'à ~kHz.
r = Reservoir.adex(N=32, params=Reservoir.ADEX_FAST,
                   dt=0.5, steps_per_cycle=2000,
                   σ_noise=600.0, τ_noise=15.0,
                   inhibitory_fraction=0.2, seed=7)

# 4 voix → 4 neurones spécifiques. Chacun pilote un Saw.
# freq_scale=1.0 → Hz brut. freq_offset=80 → drone baseline.
# smoothing_frames=4 → moyenne mobile, pitch moins jittery.
@d1 Reservoir.rate_voice(r;
    sources=[3, 11, 17, 25],
    shape=:saw,
    frames_per_cycle=24,
    freq_scale=1.0, freq_offset=80.0,
    lo_freq=60.0, hi_freq=2000.0,
    gain=0.22, overlap=2.5,
    smoothing_frames=4,
    drive=Reservoir.drive_const(350.0)) |> gain(0.55)

# Pulse layer sur 2 autres neurones, transposé une octave plus haut.
@d2 Reservoir.rate_voice(r;
    sources=[5, 19],
    shape=:pulse,
    frames_per_cycle=16,
    freq_scale=2.0, freq_offset=120.0,
    gain=0.15, overlap=2.0,
    smoothing_frames=2,
    drive=Reservoir.drive_const(300.0)) |> gain(0.45) |> hpf(400)

@d9 p"bd ~ ~ ~ bd ~ ~ ~" |> gain(1.2)

# Essaie : shape=:impulse pour buzz brut, :sin pour rendu doux.
# Augmente freq_scale → transpose plus haut. freq_offset → drone fixe.
# Baisse smoothing_frames=0 pour entendre le jitter des spikes.