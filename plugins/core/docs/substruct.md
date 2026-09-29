+++
examples = ["@d1 substruct(\"t f t t\", \"bd sn\")", "@d1 \"hh*8\" |> substruct(\"1 0 1 1\")   # en pipe"]
name = "substruct"
short = "Chaque pas vrai reçoit tout un cycle du pattern, tassé dedans (le substruct de Tidal)."
tags = ["tidal"]
+++

# substruct

Chaque pas vrai de la structure reçoit **tout un cycle** du pattern, compressé dans sa durée : `substruct("t f t t", "bd sn")` joue « bd sn » trois fois, dans les trois quarts marqués vrais. La structure s'écrit `t f` ou `1 0`.
