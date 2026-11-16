+++
examples = ["@d1 \"hh*8\" |> sometimesBy(0.3, rev)"]
name = "sometimesBy"
short = "Applies f with the given probability, decided per cycle."
tags = ["tidal"]
+++

# sometimesBy

Applies f with the given probability, decided per cycle.

`f` may change what the events are (`sometimesBy(0.3, gain(0.5))` works on a plain sample pattern). The decision depends only on the cycle number, so every `sometimes` of a session fires on the same cycles; pass `seed` to give one its own draw: `sometimesBy(0.3, rev; seed = 2)`. `sometimes`, `often`, `rarely`, `almostAlways`, `almostNever` and `someCyclesBy` take it too.
