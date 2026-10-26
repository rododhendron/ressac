+++
examples = ["@d1 \"bd hh sn\" |> rot(1)", "@d1 \"bd hh sn\" |> rot(\"<0 1 2>\")"]
name = "rot"
short = "Rotates the values by n notches within each cycle, rhythmic structure kept. rot(1) on \"bd hh sn\" plays hh sn bd."
tags = ["tidal"]
+++

# rot

Rotates the values by n notches within each cycle, rhythmic structure kept. rot(1) on "bd hh sn" plays hh sn bd.

Rotates the values by n steps while keeping the rhythm: `rot(1)` on `"bd hh sn"` plays `hh sn bd` on the same beats. The structure stays, the sounds move.

See also: iter, structure
