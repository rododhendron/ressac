cps!(0.45)
@d1 "bd ~ ~ ~ ~ ~ bd ~"
@d2 "~ ~ cp ~ ~ ~ cp ~"
@d3 "hh hh [hh hh hh] hh hh [hh hh hh] hh hh" |> gain(0.4)
@d4 :subdrop |> n("0 ~ ~ 0 ~ ~ 5 ~") |> gain(0.6)
