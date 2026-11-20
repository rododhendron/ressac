+++
examples = []
name = "out"
short = "Synth output bus. 0 = master left, 1 = master right. SuperDirt routes through DirtPan with it."
tags = ["param"]
+++

# out

Synth output bus. 0 = master left, 1 = master right. SuperDirt routes through DirtPan with it.

`out` is a named parameter of a sound, not a function: nothing called `out` can be applied to a pattern. In a pattern, write `set(:out, value)`; in a sound, declare it as an argument (`@synth :name (out=…) …`) and read it as `:out`.
