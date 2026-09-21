+++
examples = ["@d1 \"bd*8\" |> whenT(t -> t - floor(t) < 1//2, fast(2))"]
name = "whenT"
short = "Applique f aux événements dont le début (en cycles) vérifie test."
tags = ["tidal"]
+++

# whenT

Applique f aux événements dont le début (en cycles) vérifie test.
