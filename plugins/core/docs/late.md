+++
examples = ["@d1 \"bd sn\" |> late(1//8)"]
name = "late"
short = "Delays the pattern by t cycles (t may be fractional)."
tags = ["tidal"]
+++

# late

Delays the pattern by t cycles (t may be fractional).

Delays the whole pattern by t cycles: `late(1//8)` pushes it an eighth back. `early` is the opposite; `nudge` works in seconds instead.

See also: early, nudge, off
