+++
examples = ["@d1 p\"bd ~ sn ~\"            # 4 events per cycle", "@d1 p\"[bd bd] ~ sn ~\"       # nested = same time, two kicks", "@d1 p\"bd <hh sn cp> bd ~\"   # < > alternates each cycle"]
name = "p"
short = "p\"bd hh sn\" — mini-notation literal. Each space-separated token = 1 event in the cycle."
tags = ["mini-notation"]
+++

# p

Mini-notation literal. `p"bd hh sn"` and `"bd hh sn"` are equivalent
on a `@dN` line. See the wiki page "Patterns et mini-notation" for the
full grammar.
