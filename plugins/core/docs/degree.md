+++
examples = ["cps!(0.5); :scale minor", "@d1 :wobble |> degree(p\"0 2 4 7\") |> gain(0.6)  # scale-aware (no #s in mini-notation)"]
name = "degree"
short = "degree(x) — like n(x) but x is a degree of the current :scale (`:scale minor` first)."
tags = ["glossary", "pitch"]
aliases = ["scale degree"]
+++

# degree

degree(x) — like n(x) but x is a degree of the current :scale (`:scale minor` first).

Like `n`, but the number is a degree of the current `:scale`: `degree("0 2 4")` is a triad in whatever key is set, and changing the scale changes the melody without rewriting it.

See also: scale, n, degree
