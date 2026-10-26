+++
examples = ["@d1 :amen |> striate(8)", "@d1 striate(4, \"bd sn\")"]
name = "striate"
short = "Plays p n times in the cycle, each repeat reading a different slice of the sample."
tags = ["tidal"]
+++

# striate

Plays p n times in the cycle, each repeat reading a different slice of the sample.

Cuts the sample into n slices and plays slice 1 on the first repeat, slice 2 on the second… so `striate(8)` on a break walks through it in order within one cycle. `chop` cuts each event instead; `slice` picks slices by pattern.

See also: chopp, slice, granular
