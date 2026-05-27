cps!(0.85)

@d1 p"k909*4" |> gain(1.6) |> shape(0.6)
@d2 gate(:supersnare, p"0 0 1 0") |> gain(1.2) |> room(0.2) |> shape(0.4)
@d3 p"hh*16" |> gain(0.4) |> hpf(8000)
@d4 :supersaw |> n(p"<-12 -8 -5 -10>") |> release(0.4) |> gain(1.3) |> lpf(p"<400 2000 800>") |> shape(0.5)
@d5 p"~ ~ ~ ~ cp ~ ~ ~" |> gain(0.9) |> shape(0.4)