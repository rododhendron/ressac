+++
examples = []
name = "depth"
short = "Modulation depth. For an LFO on the cutoff: the amplitude of the sweep around `centre`."
tags = ["param"]
+++

# depth

Modulation depth. For an LFO on the cutoff: the amplitude of the sweep around `centre`.

`depth` is a named parameter of a sound, not a function: nothing called `depth` can be applied to a pattern. In a pattern, write `set(:depth, value)`; in a sound, declare it as an argument (`@synth :name (depth=…) …`) and read it as `:depth`.
