cps!(0.2)

@d1 gate(:super808, p"1 0 0 1 0 0 1 0") |> n(-12) |> release(0.6) |> gain(1.6) |> room(0.3) |> shape(0.3)
@d2 gate(:supersnare, p"0 0 1 0") |> n(-8) |> release(0.8) |> gain(0.7) |> room(0.7) |> lpf(2000)
@d3 p"hh*8" |> speed(0.5) |> gain(0.4) |> hpf(3500) |> room(0.3)
@d4 p"superreese*4" |> n(-24) |> release(0.8) |> gain(1.4) |> lpf(180) |> shape(0.5)
@d5 p"superhammond*2" |> n(p"-12 -5 -8 -3") |> release(2.5) |> attack(0.5) |> gain(0.5) |> lpf(1200) |> room(0.6)