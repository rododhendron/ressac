+++
examples = ["@d1 p\"bd hh sn hh\" |> fast(2)        # twice as fast", "@d1 p\"bd hh\" |> every(4, fast(3))    # triplet every 4th cycle"]
name = "fast"
short = "fast(n, p) or `p |> fast(n)` — compresses time ×n. fast(2) plays twice per cycle."
tags = []
+++

# fast

fast(n, p) or `p |> fast(n)` — compresses time ×n. fast(2) plays twice per cycle.

Squeezes the pattern so it plays n times per cycle: `fast(2)` twice, `fast(1.5)` one and a half times (it realigns every two cycles). Combined with `every` it makes fills: `every(4, fast(2))`. `slow` is the inverse; `hurry` also raises the pitch of samples.

See also: slow, hurry, cycle
