# Juke / 160bpm Chicago ghetto-house — fast hats, tight kicks
# (RP Boo / DJ Rashad lineage, AlgoRave repertoire).
cps!(0.66)

@d1 p"bd ~ bd ~ ~ ~ bd ~ ~ ~ bd ~ ~ ~ ~ ~" |> gain(1.3)
@d2 p"~ ~ ~ ~ cp ~ ~ ~ ~ cp ~ ~ ~ ~ cp ~" |> gain(0.7) |> room(0.2)
@d3 p"hh*16" |> gain(0.35) |> hpf(6000)
@d4 p"~ ~ vox ~ ~ ~ vox ~" |> speed(p"<1 0.85 1.2 1>") |> gain(0.5)
@d5 :supersaw |> n(p"-5 -7 -10 ?") |> release(0.2) |> gain(0.5)