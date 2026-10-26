+++
examples = ["@d1 \"hh*8\" |> pan(rand_pat() |> segment(8))"]
name = "rand_pat"
short = "Continuous random signal between 0 and 1 (Tidal's rand)."
tags = ["signal"]
+++

# rand_pat

Continuous random signal between 0 and 1 (Tidal's rand).

A continuous random signal between 0 and 1 (Tidal's `rand`). Sample it with `segment` before feeding a control: `pan(rand_pat() |> segment(8))`.

See also: segment, irand, perlin
