# Breakbeat — classic 'Amen' chop idiom
# (commonly taught in the Tidal tutorial as the breaks starter)
cps!(0.56)

@d1 p"amencutup*4" |> n(p"<0 1 2 3 4 5>") |> gain(1.2)
@d2 gate(:super808, p"1 0 0 0 0 0 0 0") |> n(-12) |> release(0.4) |> gain(1.3)
@d3 p"~ ~ cp ~" |> gain(0.7) |> room(0.3)
@d4 :superreese |> n(p"<-15 -12 -10>") |> release(0.7) |> gain(0.8) |> lpf(p"<600 1500>")