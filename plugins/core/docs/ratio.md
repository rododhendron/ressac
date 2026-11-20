+++
examples = []
name = "ratio"
short = "Compressor ratio (1 = no compression, 4 = 4:1, ∞ = limiter)."
tags = ["param"]
+++

# ratio

Compressor ratio (1 = no compression, 4 = 4:1, ∞ = limiter).

`ratio` is a named parameter of a sound, not a function: nothing called `ratio` can be applied to a pattern. In a pattern, write `set(:ratio, value)`; in a sound, declare it as an argument (`@synth :name (ratio=…) …`) and read it as `:ratio`.
