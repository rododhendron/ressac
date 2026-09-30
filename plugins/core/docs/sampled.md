+++
examples = ["@d1 :bd |> sampled(n(\"0 1 2\"))    # un seul coup, n = 0 (le # strict)", "@d1 \"bd*4\" |> sampled(lpf(\"<400 800 1600>\"))"]
name = "sampled"
short = "Strict left structure (Tidal's #): even a sound without rhythm keeps its single event."
tags = ["tidal"]
+++

# sampled

By default a pattern-valued control keeps the left structure (every event reads the value at its onset), **except** for a sound without rhythm (`:bd`, `"bd"`), which takes the rhythm of the control. `sampled(f)` forces the left side even there — exactly Tidal's `#`: `:bd |> sampled(n("0 1 2"))` makes a single hit. See `both` for the intersection.
