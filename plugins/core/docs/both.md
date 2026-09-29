+++
examples = ["@d1 \"bd sn\" |> both(gain(\"1 0.5 1 0.5\"))    # quatre fragments", "@d1 \"bd*4\" |> both(n(\"0 1 2\"))            # six coups"]
name = "both"
short = "Structure des deux côtés (le |>| de Tidal) : les événements sont découpés aux intersections."
tags = ["tidal"]
+++

# both

Applique l'étape avec la structure des **deux** côtés : chaque événement est découpé là où le contrôle change, et chaque fragment redéclenche. C'est ce que font `pump` et `bend`. Le défaut (`"bd*4" |> n("0 1 2")`) garde la structure de gauche : quatre coups qui lisent `n` à leur attaque.
