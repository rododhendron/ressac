# ╭─ Voice / mic / line input drives the reservoir ─╮
# │  1) `:audio-in start`  → starts SC's mic listener
# │  2) eval the buffer    → reservoir pilots a melody
# │  3) parle / chante     → V monte avec ton volume,
# │                          le réseau spike en sync
# ╰────────────────────────────────────────────────────╯
cps!(0.5)

# Bring up the audio-in bridge (does nothing without SC running).
# In the TUI command line: `:audio-in start`  (et stop pour libérer)

# Reservoir with cortical-style noise so the mic input pushes
# already-near-threshold neurons over the edge.
r = Reservoir.adex(N=24, params=Reservoir.ADEX_BURSTING,
                   σ_noise=400.0, seed=42)

# drive=:audio_in pulls the latest RMS amplitude from the mic
# (scaled to pA). Quiet input → almost silent ; loud → dense spikes.
@d1 Reservoir.pool_burst(r;
    bins=8, frames_per_cycle=8,
    layout=:scale, layout_args=(scale=:minor_pentatonic, root=220),
    drive=:audio_in,
    gain_per_spike=0.05, max_gain=0.7) |> gain(0.5)

# Anchor with a kick so silence vs voice contrast is audible.
@d9 p"bd ~ ~ ~ bd ~ ~ ~" |> gain(1.2)