cps!(0.5)

@d1 gate(:super808, p"1 0 0 0 1 0 0 0 1 0 0 0 1 0 0 0") |> n(-12) |> release(0.4) |> gain(1.4)
@d2 gate(:supersnare, p"0 0 0 0 1 0 0 0 0 0 0 0 1 0 0 0") |> gain(0.9) |> room(0.2)
@d3 p"hh*8" |> gain(0.35) |> hpf(4000) |> pan(p"0.4 -0.4")
@d4 p"superreese*2" |> n(p"-12 -7") |> release(0.6) |> gain(1.0) |> lpf(800)