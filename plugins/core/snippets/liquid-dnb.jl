# Liquid drum & bass — smooth pad, rolling break, sub on 1+3
# (LTJ Bukem / Calibre lineage — 174 BPM half-time feel)
cps!(0.72)

@d1 p"bd ~ ~ ~ ~ ~ sn ~ ~ ~ bd ~ ~ ~ sn ~" |> gain(1.2)
@d2 p"hh*16" |> gain(0.3) |> hpf(5500) |> degradeBy(0.1)
@d3 :subdrop |> n(p"0 ~ ~ ~ 0 ~ 5 ~") |> release(1.2) |> gain(0.8)
@d4 :softpad |> n(p"<0 5 7 3>") |> release(2.0) |> attack(0.3) |> gain(0.35) |> room(0.6)
@d5 p"~ ~ ~ cp ~ ~ ~ ~" |> gain(0.6) |> room(0.5)