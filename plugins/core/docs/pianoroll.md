+++
examples = ['@d1 n("0 3 7 12") |> s("superpiano") |> pianoroll()']
name = "pianoroll"
short = "Shows this slot's piano roll in the editor; the pattern is unchanged."
tags = ["view"]
+++

# pianoroll

Shows this slot's piano roll in the editor; the pattern is unchanged.

Asks for a visual where the pattern is written, as in Strudel. The roll is drawn in pixels under the slot's block, across the text (kitty graphics protocol): one bar per note at its pitch and length, the sounding note lit, the playhead across. It stays on screen wherever the cursor is.

Without it, the roll of the slot under the cursor is shown at the bottom of the cycle grid. In a terminal without pixel graphics it draws nothing.
