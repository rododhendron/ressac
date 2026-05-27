cps!(0.46)
@d1 "bd ~ ~ bd ~ bd ~ ~"
@d2 "~ cp ~ ~ ~ cp ~ ~"
@d3 "[hh hh hh]*4" |> gain(0.35)
@d4 "cb ~ ~ cb ~ ~ cb ~" |> gain(0.5)
@d5 :subdrop |> n("0 ~ ~ 0 -3 ~ ~ ~") |> gain(0.7)
