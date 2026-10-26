+++
examples = ["@d1 \"hh*16\" |> degrade"]
name = "degrade"
short = "Drops half of the events (degradeBy(0.5)), deterministically."
tags = ["tidal"]
+++

# degrade

Drops half of the events (degradeBy(0.5)), deterministically.

Drops half of the events at random, deterministically: a `"hh*16"` becomes a broken hat line that repeats identically. `degradeBy(0.2)` drops fewer; `unDegradeBy` keeps exactly the ones it would drop.

See also: degradeBy, sometimes
