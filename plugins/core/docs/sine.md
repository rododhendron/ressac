+++
examples = ["@d1 \"hh*8\" |> pan(sine() |> segment(8))"]
name = "sine"
short = "Continuous sine signal, one period per cycle, from -1 to 1."
tags = ["signal", "glossary", "synthesis"]
aliases = ["sine wave", "sinusoid"]
+++

# sine

Continuous sine signal, one period per cycle, from -1 to 1.

`sin_osc(:freq)` in the DSL; `sine()` as a pattern is the same shape running once per cycle, from -1 to 1, handy for slow modulation.

See also: waveform, harmonic, LFO
