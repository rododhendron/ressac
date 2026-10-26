+++
examples = ["@d1 \"hh*8\" |> swingBy(1//3, 4)"]
name = "swingBy"
short = "Swing: within each of the n slots, whatever falls in the second half is delayed by x slot."
tags = ["tidal"]
+++

# swingBy

Swing: within each of the n slots, whatever falls in the second half is delayed by x slot.

Delays every other subdivision by a fraction of a step: `swingBy(1//3, 4)` is a classic triplet swing on four steps. `swing(n)` is the shortcut with 1//3.

See also: swing, nudge
