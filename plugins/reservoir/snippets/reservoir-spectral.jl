# Route II — RECA rule 110 over harmonic partials.
# Rule 110 is Turing-complete (edge of chaos). Try 30 (fully
# chaotic), 90 (Sierpinski), 184 (traffic) for very different
# spectra.
cps!(0.4)

r = Reservoir.reca(N=16, rule=110, init=:single)

@d1 Reservoir.spectral_cloud(r; frames_per_cycle=8, layout=:harmonic, layout_args=(fund=110,)) |> gain(0.55)

@d2 p"~ ~ cp ~" |> gain(0.5) |> room(0.4)