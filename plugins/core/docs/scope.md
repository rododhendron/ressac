+++
examples = ['@d1 n("0 3 7 12") |> s("superpiano") |> scope()']
name = "scope"
short = "Shows the output waveform under this slot's line; the pattern is unchanged."
tags = ["view"]
+++

# scope

Shows the output waveform under this slot's line; the pattern is unchanged.

The waveform is the one of `:scope wave`: the main output, not this slot alone (there is no per-slot audio tap). Evaluating a slot that asks for `scope()` turns the wave scope on if it was off. Drawn in pixels under the slot's block (kitty graphics protocol).
