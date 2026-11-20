+++
examples = []
name = "rq"
short = "Reciprocal Q of the SuperCollider filters (RLPF, RHPF). 1.0 = no resonance, 0.1 = very resonant."
tags = ["param"]
+++

# rq

Reciprocal Q of the SuperCollider filters (RLPF, RHPF). 1.0 = no resonance, 0.1 = very resonant.

`rq` is a named parameter of a sound, not a function: nothing called `rq` can be applied to a pattern. In a pattern, write `set(:rq, value)`; in a sound, declare it as an argument (`@synth :name (rq=…) …`) and read it as `:rq`.
