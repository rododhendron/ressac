+++
examples = ["@d1 :bd |> sampled(n(\"0 1 2\"))    # un seul coup, n = 0 (le # strict)", "@d1 \"bd*4\" |> sampled(lpf(\"<400 800 1600>\"))"]
name = "sampled"
short = "Structure de gauche stricte (le # de Tidal) : même un son sans rythme garde son unique événement."
tags = ["tidal"]
+++

# sampled

Par défaut un contrôle à valeur pattern garde la structure de gauche (chaque événement lit la valeur à son attaque), **sauf** pour un son sans rythme (`:bd`, `"bd"`), qui prend le rythme du contrôle. `sampled(f)` impose la gauche même là — c'est exactement le `#` de Tidal : `:bd |> sampled(n("0 1 2"))` fait un seul coup. Voir `both` pour l'intersection.
