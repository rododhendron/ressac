+++
examples = ["@d1 p\"bd ~ sn ~\"            # 4 events per cycle", "@d1 p\"[bd bd] ~ sn ~\"       # nested = same time, two kicks", "@d1 p\"bd <hh sn cp> bd ~\"   # < > alternates each cycle"]
name = "p"
short = "p\"bd hh sn\" — littéral de mini-notation. Chaque token séparé par un espace = 1 événement dans le cycle."
tags = ["mini-notation"]
+++

# p

Littéral de mini-notation. `p"bd hh sn"` et `"bd hh sn"` sont
équivalents dans une ligne `@dN`. Voir la page « Patterns et
mini-notation » du wiki pour la grammaire complète.
