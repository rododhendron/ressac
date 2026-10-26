+++
examples = ["@d1 :bd |> orbit(1)"]
name = "orbit"
short = "SuperDirt orbit (independent effect bus)."
tags = ["tidal", "glossary", "supercollider", "mix"]
aliases = ["orbits"]
+++

# orbit

SuperDirt orbit (independent effect bus).

Which effect bus the slot plays on. Each slot has its own by default (slot d1 → orbit 0), so a wet reverb on one voice never touches another. Setting the same orbit on two slots makes them share reverb and delay.

See also: orbit, room, delay
