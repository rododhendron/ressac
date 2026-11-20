+++
examples = []
name = "velocity"
short = "Note velocity (0-1). Often mapped to amplitude or cutoff."
tags = ["param"]
+++

# velocity

Note velocity (0-1). Often mapped to amplitude or cutoff.

How hard the note is hit, 0 to 1. Synths map it to amplitude or brightness; it is the natural control for human-like accents (`set(:velocity, "0.9 0.5 0.7 0.5")`).

See also: gain, amplitude

`velocity` is a named parameter of a sound, not a function: nothing called `velocity` can be applied to a pattern. In a pattern, write `set(:velocity, value)`; in a sound, declare it as an argument (`@synth :name (velocity=…) …`) and read it as `:velocity`.
