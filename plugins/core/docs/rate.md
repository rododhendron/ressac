+++
examples = []
name = "rate"
short = "LFO speed in Hz. 4 = 4 cycles/s, 0.5 = slow swell, 16 = fast wobble."
tags = ["param"]
+++

# rate

LFO speed in Hz. 4 = 4 cycles/s, 0.5 = slow swell, 16 = fast wobble.

`rate` is a named parameter of a sound, not a function: nothing called `rate` can be applied to a pattern. In a pattern, write `set(:rate, value)`; in a sound, declare it as an argument (`@synth :name (rate=…) …`) and read it as `:rate`.
