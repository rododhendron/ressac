cps!(0.55)

@d1 p"bd(3,8,<0 1 2>)" |> gain(1.2)
@d2 p"cp(5,16,<2 4>)" |> gain(0.7) |> room(0.3)
@d3 p"hh(11,16)" |> gain(0.3) |> hpf(6000) |> degradeBy(0.4) |> pan(p"<0 0.7 0.3 -0.5>")
@d4 :supersaw |> n(p"0 7 5 ? 12 ?") |> release(0.3) |> gain(0.6) |> lpf(p"<300 1800 600>") |> shape(0.3)
@d5 p"glitch ~ ~ glitch" |> gain(0.5) |> sometimes(rev) |> crush(6)