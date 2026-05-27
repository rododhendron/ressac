cps!(0.15)

@d1 p"superhammond" |> n(p"-12 -5 -8 -3 0 -3 -5 -8") |> release(4.0) |> attack(1.0) |> gain(0.4) |> lpf(800) |> room(0.85) |> delay(0.4)
@d2 p"superfork" |> n(p"24 19 12 19 24 19 12 24") |> release(3.0) |> gain(0.3) |> room(0.9)
@d3 p"supersine*1" |> n(-36) |> release(8.0) |> gain(0.5) |> lpf(120) |> shape(0.2)