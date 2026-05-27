cps!(0.4)

@d1 gate(:super808, p"1 0 0 1 0 0 0 1") |> n(-12) |> release(0.5) |> gain(1.6)
@d2 gate(:supersnare, p"0 0 1 0") |> gain(1.0) |> room(0.15)
@d3 p"hh*16" |> gain(0.3) |> hpf(5000) |> pan(p"0.3 -0.3 0.1 -0.1")
@d4 p"super808" |> n(p"-24 -22 -19 -17") |> release(1.0) |> gain(1.3) |> lpf(250) |> shape(0.4)