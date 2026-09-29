+++
examples = ["@d1 \"bd sn\" |> slow(secs(2))         # deux secondes par cycle, quel que soit le cps", "@d1 \"hh*4\" |> delaytime(secs(0.25))"]
name = "secs"
short = "Des secondes en cycles, au tempo courant (lu à chaque requête)."
tags = ["tidal"]
+++

# secs

Convertit des secondes en cycles au cps courant, lu à chaque requête : un changement de tempo est suivi. Nombre, chaîne ou pattern. (`sec` est la sécante de Julia, d'où le nom.)
