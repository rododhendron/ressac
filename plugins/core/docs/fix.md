+++
examples = ["@d1 \"bd hh bd\" |> fix(fast(2), :s => :bd)", "@d1 :bd |> n(\"0 1 2\") |> fix(x -> x |> gain(0.3), :n => 2)"]
name = "fix"
short = "Applique f aux seuls événements dont les contrôles correspondent."
tags = ["tidal"]
+++

# fix

Applique f aux seuls événements dont les contrôles correspondent.
