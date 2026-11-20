+++
examples = []
name = "pitchshift"
short = "Transposition (semitones)."
tags = ["param"]
+++

# pitchshift

Transposition (semitones).

`pitchshift` is a named parameter of a sound, not a function: nothing called `pitchshift` can be applied to a pattern. In a pattern, write `set(:pitchshift, value)`; in a sound, declare it as an argument (`@synth :name (pitchshift=…) …`) and read it as `:pitchshift`.
