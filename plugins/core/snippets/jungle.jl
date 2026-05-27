cps!(0.7)

@d1 p"amen*2" |> gain(1.2) |> speed(1.1) |> shape(0.2)
@d2 gate(:super808, p"1 0 0 0 0 0 1 0") |> n(-12) |> release(0.5) |> gain(1.4)
@d3 p"~ ~ cp ~" |> gain(0.6) |> room(0.4) |> shape(0.3)
@d4 :superreese |> n(p"-24 -19 -17 -12") |> release(1.5) |> gain(1.0) |> lpf(p"<500 1500>")
@d5 p"hh*16" |> gain(0.2) |> hpf(7000) |> degradeBy(0.3)