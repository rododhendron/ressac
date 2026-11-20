+++
examples = []
name = "threshold"
short = "Compressor / gate threshold (in dB or as an amplitude 0-1)."
tags = ["glossary", "effects", "mix", "param"]
+++

# threshold

Compressor / gate threshold (in dB or as an amplitude 0-1).

See also: compressor, decibel

`threshold` is a named parameter of a sound, not a function: nothing called `threshold` can be applied to a pattern. In a pattern, write `set(:threshold, value)`; in a sound, declare it as an argument (`@synth :name (threshold=…) …`) and read it as `:threshold`.
