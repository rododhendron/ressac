cps!(0.42)

@d1 gate(:super808, p"1 0 0 1") |> gain(1.2) |> shape(0.3) |> lpf(2000)
@d2 gate(:supersnare, p"0 0 1 0") |> gain(0.7) |> hpf(200) |> lpf(3000) |> room(0.4)
@d3 p"hh*4" |> gain(0.3) |> hpf(2500) |> lpf(6000)
@d4 p"superhammond*2" |> n(p"0 -5 -8 -3") |> release(1.5) |> gain(0.5) |> lpf(1800) |> room(0.5) |> crush(7)