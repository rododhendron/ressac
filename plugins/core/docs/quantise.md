+++
examples = ["@d1 :pad |> n(quantise(sine() |> range_pat(0, 7) |> segment(4)))"]
name = "quantise"
short = "Rounds every numeric value to the nearest integer."
tags = ["tidal", "glossary", "pattern", "digital"]
aliases = ["quantize", "quantisation"]
+++

# quantise

Rounds every numeric value to the nearest integer.

`quantise` rounds pattern values; `round_q` staircases a signal in the DSL.

See also: scale, bit crushing
