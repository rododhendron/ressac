+++
examples = ["@d1 \"bd*4\" |> sampled(n(\"0 1 2\"))    # 4 coups, n lu à l'attaque", "@d1 \"bd sn\" |> sampled(lpf(\"<400 800 1600>\"))"]
name = "sampled"
short = "Structure de gauche seule (le # de Tidal) : l'événement garde sa durée et lit le contrôle à son attaque."
tags = ["tidal"]
+++

# sampled

Par défaut un contrôle à valeur pattern découpe les événements aux intersections (structure des deux côtés, le `|>|` de Tidal). `sampled(f)` garde la structure de **gauche** : chaque événement lit la valeur de `f` à son attaque et garde sa durée — c'est le `#` de Tidal. `"bd*4" |> sampled(n("0 1 2"))` fait quatre coups (n = 0, 0, 1, 2) là où `"bd*4" |> n("0 1 2")` en découpe six.
