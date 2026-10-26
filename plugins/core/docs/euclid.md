+++
examples = ["@d1 :bd |> euclid(3, 8)", "@d1 \"bd sn\" |> euclid(5, 8)"]
name = "euclid"
short = "Euclidean rhythm, k hits over n steps, values taken from the pattern: euclid(3, 8)."
tags = ["tidal"]
+++

# euclid

Euclidean rhythm, k hits over n steps, values taken from the pattern: euclid(3, 8).

Spreads k hits as evenly as possible over n steps: `euclid(3, 8)` is the tresillo, `euclid(5, 8)` the cinquillo, `euclid(7, 16)` a common hat line. The mini-notation form `"bd(3,8)"` is the same; `euclidOff` rotates, `euclidInv` plays the gaps.

See also: Euclidean rhythm, euclidOff, mini-notation
