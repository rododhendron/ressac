+++
examples = []
name = "fade"
short = "Fade-in or crossfade time (s)."
tags = ["param"]
+++

# fade

Fade-in or crossfade time (s).

`fade` is a named parameter of a sound, not a function: nothing called `fade` can be applied to a pattern. In a pattern, write `set(:fade, value)`; in a sound, declare it as an argument (`@synth :name (fade=…) …`) and read it as `:fade`.
