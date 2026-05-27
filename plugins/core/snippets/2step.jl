# UK 2-step garage — the syncopated kick + swung snare idiom
# (Wookie/MJ Cole/Todd Edwards era, mid-90s UK)
cps!(0.55)

@d1 p"bd ~ ~ bd ~ ~ bd ~" |> gain(1.2)
@d2 p"~ ~ cp ~ ~ ~ ~ cp" |> gain(0.8) |> room(0.3)
@d3 p"~ hh ~ hh ~ hh ~ hh" |> gain(0.4) |> hpf(5000)
@d4 :superpiano*2 |> n(p"0 5 7 12") |> release(0.3) |> gain(0.5) |> room(0.4)
@d5 :superreese |> n(p"<-12 -10 -7 -10>") |> release(0.4) |> gain(0.7) |> lpf(800)