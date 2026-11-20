+++
examples = []
name = "mix"
short = "Dry/wet mix of an effect (0 = dry, 1 = wet)."
tags = ["param"]
+++

# mix

Dry/wet mix of an effect (0 = dry, 1 = wet).

`mix` is a named parameter of a sound, not a function: nothing called `mix` can be applied to a pattern. In a pattern, write `set(:mix, value)`; in a sound, declare it as an argument (`@synth :name (mix=…) …`) and read it as `:mix`.
