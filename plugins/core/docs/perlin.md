+++
examples = ["@d1 \"hh*8\" |> lpf(perlin() |> range_pat(300, 5000) |> segment(8))"]
name = "perlin"
short = "Smoothed random noise between 0 and 1, drifting slowly from one cycle to the next."
tags = ["signal"]
+++

# perlin

Smoothed random noise between 0 and 1, drifting slowly from one cycle to the next.
