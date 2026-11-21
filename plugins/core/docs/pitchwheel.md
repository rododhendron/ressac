+++
examples = ['@d1 n("0 3 7 12") |> s("superpiano") |> pitchwheel()']
name = "pitchwheel"
short = "Shows this slot's pitch wheel in the editor; the pattern is unchanged."
tags = ["view"]
+++

# pitchwheel

Shows this slot's pitch wheel in the editor; the pattern is unchanged.

Asks for a visual where the pattern is written, as in Strudel. The wheel is drawn in pixels under the slot's block, across the text (kitty graphics protocol): twelve positions, `0` (C) at the top; the notes of the cycle are marked, the ones sounding now are lit and joined.

In a terminal without pixel graphics it draws nothing.
