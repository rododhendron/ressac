+++
examples = []
name = "moddepth"
short = "Depth / amplitude of the FM modulator."
tags = ["param"]
+++

# moddepth

Depth / amplitude of the FM modulator.

`moddepth` is a named parameter of a sound, not a function: nothing called `moddepth` can be applied to a pattern. In a pattern, write `set(:moddepth, value)`; in a sound, declare it as an argument (`@synth :name (moddepth=…) …`) and read it as `:moddepth`.
