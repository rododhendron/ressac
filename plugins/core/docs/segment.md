+++
examples = ["@d1 \"hh*8\" |> pan(sine() |> segment(8))"]
name = "segment"
short = "Samples a continuous signal n times per cycle to turn it into events."
tags = ["signal"]
+++

# segment

Samples a continuous signal n times per cycle to turn it into events.

Turns a continuous signal into n events per cycle: `sine() |> segment(8)` is eight values along a sine. Needed before feeding `sine`, `rand_pat`, `perlin` or `irand` to a control, because a control reads a value at each onset.

See also: sine, rand_pat, perlin, structure
