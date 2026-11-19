+++
examples = ["@d1 p\"bd*3 bd\" |> s(\"superpiano\") |> nTake([0, 3, 7])", "@d1 p\"x(5,8)\" |> s(\"superpiano\") |> nTake([0, 7, 12, 3])"]
name = "nTake"
short = "Gives each hit the next note of a list, in order, whatever the rhythm."
tags = ["tidal"]
+++

# nTake

Gives each hit the next note of `values`, in order and looping, whatever the rhythm.

The list advances by one step per hit, not per cycle: with three notes and four hits, the first cycle plays `0 3 7 0`, the next `3 7 0 3`. That is what sets it apart from `n("0 3 7")`, which restarts every cycle.

The rank of a hit is the number of hits since cycle 0, so the same moment always gets the same note: evaluating twice changes nothing.
