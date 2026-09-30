+++
examples = ["@d1 \"bd sn\" |> slow(secs(2))         # deux secondes par cycle, quel que soit le cps", "@d1 \"hh*4\" |> delaytime(secs(0.25))"]
name = "secs"
short = "Seconds as cycles, at the current tempo (read on every query)."
tags = ["tidal"]
+++

# secs

Converts seconds to cycles at the current cps, read on every query: a tempo change is followed. Number, string or pattern. (`sec` is Julia's secant, hence the name.)
