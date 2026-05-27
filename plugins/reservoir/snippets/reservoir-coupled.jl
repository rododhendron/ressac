# ╭─ E/I coupled populations ─╮
# │  Excitatory pool drives inhibitory pool;
# │  inhibitory pool damps the excitatory pool.
# │  E/I balance = comme cortex biologique.
# ╰──────────────────────────────╯
cps!(0.5)

r_E = Reservoir.adex(N=24, params=Reservoir.ADEX_REGULAR_BURST,
                     σ_noise=400.0, seed=1)
r_I = Reservoir.adex(N=6,  params=Reservoir.ADEX_FAST,
                     σ_noise=300.0, seed=2)

# E and I in one group; output_idx=1 → routes lisent r_E
g = Reservoir.couple([r_E, r_I]; output_idx=1)

# Excitateurs activent inhibiteurs (E → I)
Reservoir.connect!(g, 1, 2; gain=300, p_connect=0.3, sign=:positive)

# Inhibiteurs amortissent excitateurs (I → E)
Reservoir.connect!(g, 2, 1; gain=400, p_connect=0.4, sign=:negative)

@d1 Reservoir.pool_burst(g;
    bins=8, frames_per_cycle=8,
    layout=:scale, layout_args=(scale=:dorian, root=110),
    drive=500.0,
    gain_per_spike=0.05) |> gain(0.5)

@d9 p"bd ~ ~ ~ bd ~ ~ ~" |> gain(1.2)