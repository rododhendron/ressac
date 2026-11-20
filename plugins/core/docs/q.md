+++
examples = []
name = "q"
short = "Filter resonance / quality (inverse of 'rq'). 0.1 = sharp peak, 0.5 = medium, 1 = no resonance. More q = more whistle."
tags = ["param"]
+++

# q

Filter resonance / quality (inverse of 'rq'). 0.1 = sharp peak, 0.5 = medium, 1 = no resonance. More q = more whistle.

`q` is a named parameter of a sound, not a function: nothing called `q` can be applied to a pattern. In a pattern, write `set(:q, value)`; in a sound, declare it as an argument (`@synth :name (q=…) …`) and read it as `:q`.
