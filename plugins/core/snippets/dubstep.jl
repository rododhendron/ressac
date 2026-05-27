cps!(0.34)

@d1 gate(:super808, p"1 0 0 0 0 0 0 0") |> n(-12) |> release(0.6) |> gain(1.6)
@d2 gate(:supersnare, p"0 0 0 0 1 0 0 0") |> gain(1.0) |> room(0.25) |> shape(0.2)
@d3 p"hh*8" |> gain(0.25) |> hpf(5500) |> degradeBy(0.2)
@d4 p"superreese*2" |> n(p"<-12 -10 -8 -10>") |> release(0.5) |> gain(1.4) |> lpf(p"<400 1600 800 2400>") |> shape(0.4)
@d5 p"~ ~ cp ~ ~ ~ cp ~" |> gain(0.6) |> room(0.4)