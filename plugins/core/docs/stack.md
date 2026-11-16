+++
examples = ["@d1 stack(p\"bd*4\", p\"~ cp ~ cp\")     # layered drums"]
name = "stack"
short = "stack(p, q, ...) — plays the patterns in parallel (layers them)."
tags = []
+++

# stack

stack(p, q, ...) — plays the patterns in parallel (layers them).

Layers patterns so they play at the same time, in one slot: `stack("bd*4", "~ cp ~ cp")` is a kick and a clap sharing an orbit and a mixer line. The layers need not be of the same kind: `stack("bd*4", "hh*8" |> gain(0.6))` mixes a plain pattern and one with controls. At the pipe: `"bd*4" |> stack("hh*8")`. Several slots do the same with independent mute, gain and effects.

See also: overlay, slot, cat
