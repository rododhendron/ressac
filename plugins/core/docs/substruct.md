+++
examples = ["@d1 substruct(\"t f t t\", \"bd sn\")", "@d1 \"hh*8\" |> substruct(\"1 0 1 1\")   # en pipe"]
name = "substruct"
short = "Every true step receives a whole cycle of the pattern, squashed into it (Tidal's substruct)."
tags = ["tidal"]
+++

# substruct

Every true step of the structure receives a **whole cycle** of the pattern, squashed into its duration: `substruct("t f t t", "bd sn")` plays "bd sn" three times, in the three quarters marked true. The structure is written `t f` or `1 0`.
