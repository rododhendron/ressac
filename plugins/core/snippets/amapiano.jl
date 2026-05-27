cps!(0.46)

@d1 gate(:super808, p"1 0 0 0 1 0 0 0") |> n(-12) |> release(0.5) |> gain(1.4)
@d2 p"~ ~ cp ~ ~ ~ cp ~" |> gain(0.7) |> room(0.3)
@d3 p"hh*16" |> gain(0.3) |> hpf(4500) |> degradeBy(0.15)
@d4 p"superpiano*4" |> n(p"0 -3 5 7") |> release(0.6) |> gain(0.55) |> room(0.4) |> degradeBy(0.3)
@d5 :superreese |> n(p"<-12 -10 -7 -5>") |> release(0.8) |> gain(1.0) |> lpf(900) |> pump(8, 0.5)