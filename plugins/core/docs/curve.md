+++
examples = ["@d1 \"hh*8\" |> pan(curve(t -> sin(2pi * t)^3) |> segment(8))"]
name = "curve"
short = "Any function of time becomes a signal; it receives the position in the cycle, from 0 to 1."
tags = ["maths"]
+++

# curve

Any function of time becomes a signal; it receives the position in the cycle, from 0 to 1.
