+++
examples = ["@d1 slice(8, \"7 6 5 4 3 2 1 0\", :amen)", "@d1 :break |> slice(4, \"0 [1 2] 3\")"]
name = "slice"
short = "Plays slice ipat (out of n) of the sample, structure from ipat."
tags = ["tidal"]
+++

# slice

Plays slice ipat (out of n) of the sample, structure from ipat.

Plays the slice `i` out of `n` of the sample, with the structure of the index pattern: `slice(8, "0 2 7 3")` rearranges a break by hand. `splice` does the same and stretches each slice to fill its slot.

See also: striate, splice, granular
