+++
examples = ["@d1 \"bd sn\" |> off(1//8, x -> x |> gain(0.5))", "@d1 :pad |> n(\"0 3\") |> off(1//4, add(:n, 12))"]
name = "off"
short = "Superimposes a copy shifted by t cycles and transformed by f."
tags = ["tidal"]
+++

# off

Superimposes a copy shifted by t cycles and transformed by f.

Plays the pattern, plus a copy that starts `t` cycles later and goes through `f`: `off(1//8, x -> x |> gain(0.5))` is a quiet echo, `off(1//4, add(:n, 12))` an octave-up answer. Stack several `off`s for a canon.

See also: stut, superimpose, late
