# All three routes at once — spikes fire notes, a separate
# reservoir's neuron drives a filter cutoff, drums anchor it.
cps!(0.45)

r1 = Reservoir.adex(N=24, params=Reservoir.ADEX_BURSTING, seed=7)
r2 = Reservoir.adex(N=8, seed=11)

@d1 Reservoir.spike_burst(r1; drive=600.0, layout=:scale, layout_args=(scale=:dorian, root=110)) |> gain(0.4)

@d2 :supersaw |> n(p"0 ~ 5 ~ 7 ~ 3 ~") |> set(:cutoff, Reservoir.modulator(r2, neuron=5, drive=500.0) |> range_pat(600, 3500)) |> gain(0.5)

@d3 p"bd ~ ~ ~ bd ~ ~ ~" |> gain(1.3)
@d4 p"~ ~ cp ~" |> gain(0.5) |> room(0.3)