+++
examples = ["@d1 \"bd hh sn hh\" |> whenmod(8, 6, rev)"]
name = "whenmod"
short = "Applies f to the cycles whose number modulo a is ≥ b: whenmod(8, 6, rev) reverses cycles 6 and 7."
tags = ["tidal"]
+++

# whenmod

Applies f to the cycles whose number modulo a is ≥ b: whenmod(8, 6, rev) reverses cycles 6 and 7.

Applies `f` to the cycles whose number modulo `a` is at least `b`: `whenmod(8, 6, rev)` reverses cycles 6 and 7 of every 8 — a two-bar fill at the end of an eight-bar phrase.

See also: every, lastOf, within
