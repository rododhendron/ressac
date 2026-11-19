+++
examples = ["@d1 p\"hh*8\" |> nCount(5)", "@d1 :arpy |> fast(4) |> nCount()"]
name = "nCount"
short = "Gives each hit its rank as a note: 0, 1, 2…"
tags = ["tidal"]
+++

# nCount

Gives each hit its rank since cycle 0 as its note: `0, 1, 2…`. With a modulo the count wraps: `nCount(5)` plays `0 1 2 3 4 0 1…`.

Handy to walk through the variants of a sample bank.
