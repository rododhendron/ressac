+++
examples = ["@d1 \"bd*8\" |> whenT(t -> t - floor(t) < 1//2, fast(2))"]
name = "whenT"
short = "Applies f to the events whose start (in cycles) satisfies test."
tags = ["tidal"]
+++

# whenT

Applies f to the events whose start (in cycles) satisfies test.
