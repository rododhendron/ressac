+++
examples = ["@d1 \"bd sn\" |> ply(3)"]
name = "ply"
short = "Repeats each event n times within its own slot."
tags = ["tidal"]
+++

# ply

Repeats each event n times within its own slot.

Repeats each event n times within its own slot: `"bd sn" |> ply(3)` becomes `"bd*3 sn*3"`. A pattern as argument (`ply("1 3")`) makes rolls only on some steps.

See also: fast, stut
