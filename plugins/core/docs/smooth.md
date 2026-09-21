+++
examples = ["@d1 \"bd*8\" |> lpf(smooth(p\"400 2000 800\") |> range_pat(0, 1) |> segment(8))", "@d1 \"hh*8\" |> pan(smooth(p\"0 1\") |> segment(8))"]
name = "smooth"
short = "Signal continu qui interpole linéairement entre les valeurs de p."
tags = ["tidal"]
+++

# smooth

Signal continu qui interpole linéairement entre les valeurs de p.
