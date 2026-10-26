+++
examples = ["@d1 \"bd hh sn cp\" |> iter(4)"]
name = "iter"
short = "Shifts the pattern one more step each cycle, over n cycles."
tags = ["tidal"]
+++

# iter

Shifts the pattern one more step each cycle, over n cycles.

Shifts the pattern by one step more each cycle, over n cycles: `"bd hh sn cp" |> iter(4)` starts on bd, then hh, then sn, then cp. A cheap way to get four variations of one bar.

See also: rot, chunk
