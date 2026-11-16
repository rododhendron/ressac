+++
examples = ["@d1 \"hh*16\" |> degradeBy(0.3)"]
name = "degradeBy"
short = "Drops each event with the given probability, deterministically."
tags = ["tidal"]
+++

# degradeBy

Drops each event with the given probability, deterministically.

The draw is a function of the event's start time, so the same cycle always loses the same hits. Two `degradeBy` on the same grid therefore drop the same events (as in Tidal): give one of them its own `seed` to thin further — `"hh*16" |> degradeBy(0.5) |> degradeBy(0.5; seed = 1)`.
