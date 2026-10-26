+++
examples = ["@d1 \"bd hh sn hh\" |> jux(rev)", "@d1 \"bd*4\" |> jux(fast(2))"]
name = "jux"
short = "Stereo: the pattern as is on the left, f(pattern) on the right."
tags = ["tidal"]
+++

# jux

Stereo: the pattern as is on the left, f(pattern) on the right.

Stereo in one word: the pattern as it is on the left, `f(pattern)` on the right. `jux(rev)` is the classic, `jux(fast(2))` or `jux(hurry(1.5))` make the sides race each other. `juxBy(0.3, f)` keeps the two sides close.

See also: stereo, pan, rev
