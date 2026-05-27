# ╭─ noisy baseline + pattern drive — neurons sync to beats ─╮
# │  σ_noise pushes V near threshold continuously. When a
# │  pattern event injects a pulse, the population spikes
# │  in synchrony. Pure cortical computing vibes.
# ╰────────────────────────────────────────────────────────────╯
cps!(0.5)

# OU baseline (σ_noise pA, τ_noise ms) — try σ=200 quiet, 500 alive, 800 saturated
r = Reservoir.adex(N=16, seed=42, σ_noise=500.0, τ_noise=20.0)

# The drum pattern is injected as DRIVE — each event pulses a neuron
# (neuron index = hash(event.value) % N). The reservoir spikes back
# in synchrony, mapped to a pentatonic via the layout.
@d1 Reservoir.spike_burst(r;
    drive = p"bd ~ sn ~ ~ bd ~ sn ~",
    layout = :scale,
    layout_args = (scale=:minor_pentatonic, root=220),
    burst_dur = 1//16) |> gain(0.4)

# Layer the actual drums underneath the spikes for the lock-in feel
@d2 p"bd ~ sn ~ ~ bd ~ sn ~" |> gain(1.2)

# Hat for steady motion
@d3 p"hh*8" |> gain(0.2) |> hpf(5000)