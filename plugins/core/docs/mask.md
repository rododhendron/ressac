+++
examples = ["@d1 mask(p\"bd*8\", p\"1 0 1 1 0 1 0 1\")  # gate the kicks"]
name = "mask"
short = "mask(p, q::Pattern{Bool}) — filters p by q. Where q is true, p plays."
tags = []
+++

# mask

mask(p, q::Pattern{Bool}) — filters p by q. Where q is true, p plays.

Keeps the events of `p` where the boolean pattern is true: `mask("bd*8", "1 0 1 1 0 1 0 1")` gates a kick line. The booleans can be written as `t f` or `1 0`; `inv` flips them, `euclid`-style patterns make them.

See also: structPat, euclid, structure
