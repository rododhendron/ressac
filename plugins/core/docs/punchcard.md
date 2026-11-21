+++
examples = ['@d1 n("0 3 7 12") |> s("superpiano") |> punchcard()']
name = "punchcard"
short = "Shows this slot as a punch card under its line; the pattern is unchanged."
tags = ["view"]
+++

# punchcard

Shows this slot as a punch card under its line; the pattern is unchanged.

One dot per note, at its time and pitch (drums without pitch sit on one row), with a thin trail for its length. Drawn in pixels under the slot's block, across the text (kitty graphics protocol).
