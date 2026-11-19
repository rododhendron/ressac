+++
examples = ["@d1 p\"x*8\" |> sTake([:bd, :hh, :hh])", "@d1 p\"x(3,8)\" |> sTake([:bd, :cp])"]
name = "sTake"
short = "Gives each hit the next sound of a list, in order, whatever the rhythm."
tags = ["tidal"]
+++

# sTake

Like `nTake`, for the sound: each hit takes the next name of `names`, in order and looping.

The list advances by one step per hit, not per cycle.
