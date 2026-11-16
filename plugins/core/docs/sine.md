+++
examples = ["@d1 \"hh*8\" |> pan(sine() |> segment(8))"]
name = "sine"
short = "Continuous sine signal, one period per cycle, from 0 to 1."
tags = ["signal", "glossary", "synthesis"]
aliases = ["sine wave", "sinusoid"]
+++

# sine

Continuous sine signal, one period per cycle, from 0 to 1.

A continuous sine, one period per cycle. Like every signal it lives between 0 and 1 (as in Tidal), so `pan(sine())` sweeps the whole stereo field as is. With `range_pat` it maps to a control range: `lpf(sine() |> range_pat(400, 2000))` is a filter sweep, read at each onset. `segment(n)` turns it into n events per cycle when you want its rhythm too.

See also: segment, range_pat, LFO
