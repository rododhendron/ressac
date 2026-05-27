cps!(0.48)
@d1 "bd ~ ~ bd ~ ~ bd ~"
@d2 "~ ~ cp ~ ~ ~ cp ~"
@d3 "hh hh [hh*3] hh [hh*3] hh hh hh" |> gain(0.4)
@d4 :subdrop |> n("0 ~ -2 ~ -5 ~ ~ ~") |> gain(0.7)
