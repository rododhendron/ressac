+++
examples = []
name = "modfreq"
short = "Frequency of the FM modulator."
tags = ["param"]
+++

# modfreq

Frequency of the FM modulator.

`modfreq` is a named parameter of a sound, not a function: nothing called `modfreq` can be applied to a pattern. In a pattern, write `set(:modfreq, value)`; in a sound, declare it as an argument (`@synth :name (modfreq=…) …`) and read it as `:modfreq`.
