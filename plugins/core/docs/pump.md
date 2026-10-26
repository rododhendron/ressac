+++
examples = ["@d1 :pad |> pump(4, 0.7)"]
name = "pump"
short = "Sidechain-style gain ducking: a dip at the start of each step, then recovery."
tags = ["fx"]
+++

# pump

Sidechain-style gain ducking: a dip at the start of each step, then recovery.

A sidechain-style gain dip at the start of every step, then a recovery: `pump(0.5)` on a pad makes it breathe with the beat without a real sidechain. `duck` does it from a real trigger pattern.

See also: sidechain, duck, gain
