cps!(0.5)
@d1 "bd*4" |> gain(0.9)
@d2 "~ sn ~ sn" |> gain(0.7) |> room(0.2)
@d3 "hh*8" |> gain(0.35) |> hpf(4000) |> pan("0.4 -0.4")
@d4 :bass |> n("0 0 3 5") |> gain(0.6) |> lpf(800)
# Try:
#   m on @d2     → mute the snare
#   :solo d3     → only the hat
#   :tap         → tap a rhythm to replace @d5
#   :save demo   → snapshot this state
