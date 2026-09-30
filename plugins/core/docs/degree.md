+++
examples = ["cps!(0.5); :scale minor", "@d1 :wobble |> degree(p\"0 2 4 7\") |> gain(0.6)  # scale-aware (no #s in mini-notation)"]
name = "degree"
short = "degree(x) — like n(x) but x is a degree of the current :scale (`:scale minor` first)."
tags = ["glossary", "pitch"]
aliases = ["scale degree"]
+++

# degree

degree(x) — like n(x) but x is a degree of the current :scale (`:scale minor` first).

Writing degrees instead of semitones keeps a melody inside the key when you change the scale. `degree("0 2 4")` uses the current `:scale`.

See also: scale, semitone
