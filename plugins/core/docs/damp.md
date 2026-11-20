+++
examples = []
name = "damp"
short = "Damping (0-1). Reverbs: absorption of the highs. Percussion: tightness of the body."
tags = ["param"]
+++

# damp

Damping (0-1). Reverbs: absorption of the highs. Percussion: tightness of the body.

`damp` is a named parameter of a sound, not a function: nothing called `damp` can be applied to a pattern. In a pattern, write `set(:damp, value)`; in a sound, declare it as an argument (`@synth :name (damp=…) …`) and read it as `:damp`.
