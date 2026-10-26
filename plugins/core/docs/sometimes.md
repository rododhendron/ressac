+++
examples = ["@d1 \"bd*4\" |> sometimes(fast(2))"]
name = "sometimes"
short = "Applies f one cycle out of two (sometimesBy 0.5)."
tags = ["tidal"]
+++

# sometimes

Applies f one cycle out of two (sometimesBy 0.5).

Applies `f` on half of the cycles, decided per cycle and deterministic, so the same cycle always sounds the same. `rarely`, `often`, `almostAlways` are the other odds; `sometimesBy(0.3, f)` any probability.

See also: sometimesBy, rarely, degrade
