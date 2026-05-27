# ╭─ Wilson-Cowan mean field — limit-cycle population ─╮
# │  Au lieu de N neurones indépendants, deux scalaires
# │  E (excitateurs) et I (inhibiteurs) qui s'oscillent
# │  mutuellement. Les 'spikes' visibles aux routes sont
# │  sampled Bernoulli depuis E ou I selon le neurone.
# │  Tweaker τE, τI, wEE/wEI pour changer le régime.
# ╰──────────────────────────────────────────────────────╯
cps!(0.5)

r = Reservoir.meanfield(N=24, inhibitory_fraction=0.3,
                        τE=10.0, τI=20.0,
                        wEE=12, wEI=10, wIE=12, wII=2,
                        seed=1)

# Drive modeste — laisse le limit-cycle se manifester
@d1 Reservoir.pool_burst(r;
    bins=8, frames_per_cycle=8,
    layout=:scale, layout_args=(scale=:dorian, root=110),
    drive=300.0,
    gain_per_spike=0.05) |> gain(0.5)

# Module aussi un cutoff via E (rate excitatrice)
@d2 :supersaw |> n(p"0 ~ 5 ~ 7 ~ 3 ~") |>
   set(:cutoff, Reservoir.modulator(r, kind=:E, drive=400.0)
                |> range_pat(400, 4000)) |> gain(0.5)

@d9 p"bd ~ ~ ~ bd ~ ~ ~" |> gain(1.2)