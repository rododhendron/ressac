+++
examples = []
name = "freqshift"
short = "Frequency shift (Hz, signed)."
tags = ["param"]
+++

# freqshift

Frequency shift (Hz, signed).

`freqshift` is a named parameter of a sound, not a function: nothing called `freqshift` can be applied to a pattern. In a pattern, write `set(:freqshift, value)`; in a sound, declare it as an argument (`@synth :name (freqshift=…) …`) and read it as `:freqshift`.
