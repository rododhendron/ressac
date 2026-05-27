# Dub techno — Basic Channel / Maurizio idiom
# (long-decay delays + offset chord stab + minimal kick)
cps!(0.5)

@d1 p"bd bd bd bd" |> gain(1.0)
@d2 p"~ ~ cp ~" |> gain(0.5) |> room(0.6)
@d3 :supersaw |> n(p"<-12 -10 -7>") |> release(0.4) |> gain(0.45) |> lpf(900) |> delay(0.7) |> delaytime(0.5) |> delayfeedback(0.7) |> room(0.6)
@d4 p"hh ~ ~ ~ hh ~ ~ ~" |> gain(0.3) |> hpf(6000)