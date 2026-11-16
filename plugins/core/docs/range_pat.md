+++
examples = ["@d1 \"hh*8\" |> lpf(sine() |> range_pat(400, 4000) |> segment(8))"]
name = "range_pat"
short = "Remaps a continuous signal into the given interval (Tidal's range)."
tags = ["signal"]
+++

# range_pat

Remaps a continuous signal into the given interval (Tidal's range).

Maps a signal from 0..1 — the range of every signal: `sine`, `saw`, `tri`, `square`, `rand_pat`, `perlin`, the chaos and reservoir modulators — onto `lo..hi`: 0 gives `lo`, 1 gives `hi`. `sine() |> range_pat(400, 2000)`. `rangex` does the same on an exponential scale, which is what frequencies want.

See also: sine, rangex, segment
