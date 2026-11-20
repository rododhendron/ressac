+++
examples = []
name = "centre"
short = "Central value an LFO modulates around. With `depth` for symmetric sweeps."
tags = ["param"]
+++

# centre

Central value an LFO modulates around. With `depth` for symmetric sweeps.

`centre` is a named parameter of a sound, not a function: nothing called `centre` can be applied to a pattern. In a pattern, write `set(:centre, value)`; in a sound, declare it as an argument (`@synth :name (centre=…) …`) and read it as `:centre`.
