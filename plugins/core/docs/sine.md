+++
examples = ["@d1 \"hh*8\" |> pan(sine() |> segment(8))"]
name = "sine"
short = "Continuous sine signal, one period per cycle, from -1 to 1."
tags = ["signal", "glossary", "synthesis"]
aliases = ["sine wave", "sinusoid"]
+++

# sine

Continuous sine signal, one period per cycle, from -1 to 1.

A continuous sine, one period per cycle, from -1 to 1. With `segment` it becomes events; with `range_pat` it maps to a control range: `lpf(sine() |> range_pat(400, 2000) |> segment(16))` is a filter sweep.

See also: segment, range_pat, LFO
