+++
examples = ["@d1 \"bd hh sn cp\" |> chunk(4, fast(2))"]
name = "chunk"
short = "Cuts the cycle into n pieces and applies f to a different piece each cycle."
tags = ["tidal"]
+++

# chunk

Cuts the cycle into n pieces and applies f to a different piece each cycle.

Splits the cycle into n pieces and applies `f` to a different piece each cycle: `chunk(4, hurry(2))` sends a fast burst around the bar.

See also: within, iter
