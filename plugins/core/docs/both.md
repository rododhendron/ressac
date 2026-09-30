+++
examples = ["@d1 \"bd sn\" |> both(gain(\"1 0.5 1 0.5\"))    # quatre fragments", "@d1 \"bd*4\" |> both(n(\"0 1 2\"))            # six coups"]
name = "both"
short = "Structure from both sides (Tidal's |>|): events are cut at every intersection."
tags = ["tidal"]
+++

# both

Applies the stage with the structure of **both** sides: every event is cut wherever the control changes, and every fragment retriggers. This is what `pump` and `bend` do. The default (`"bd*4" |> n("0 1 2")`) keeps the left structure: four hits that read `n` at their onset.
