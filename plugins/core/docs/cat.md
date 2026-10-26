+++
examples = ["@d1 cat([p\"bd*4\", p\"bd ~ bd ~\"])   # alternate beats each cycle"]
name = "cat"
short = "cat([p, q, r]) — chains the patterns, one per cycle."
tags = []
+++

# cat

cat([p, q, r]) — chains the patterns, one per cycle.

Chains patterns one cycle after the other: `cat(["bd*4", "cp*2"])` plays the first on even cycles, the second on odd ones. `fastcat` (or `seq`) packs them into one cycle instead.

See also: fastcat, seq, randcat
