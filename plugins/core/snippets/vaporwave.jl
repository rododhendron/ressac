# Vaporwave — slow, lush, A E S T H E T I C
# (chopped samples + soft pad + tape wobble idiom)
cps!(0.26)

@d1 p"bd ~ ~ bd ~ ~ ~ ~" |> gain(1.1) |> lpf(2000)
@d2 p"~ ~ cp ~ ~ ~ ~ ~" |> gain(0.6) |> room(0.5)
@d3 :softpad |> n(p"<0 -3 -5 -7>") |> release(3.0) |> attack(0.8) |> gain(0.45) |> room(0.85) |> delay(0.3)
@d4 :superpiano |> n(p"<7 5 3 0>*2") |> release(1.5) |> gain(0.4) |> room(0.6) |> crush(8)
@d5 :subdrop |> n(p"-12 ~ ~ -12") |> release(1.5) |> gain(0.6) |> lpf(150)