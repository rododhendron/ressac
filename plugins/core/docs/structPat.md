+++
examples = ["@d1 :pad |> n(\"0 3 7 12\") |> structPat(\"1 0 1 1\")"]
name = "structPat"
short = "Takes the structure of a boolean pattern and pours the values into it (Tidal's struct)."
tags = ["tidal"]
+++

# structPat

Takes the structure of a boolean pattern and pours the values into it (Tidal's struct).

Takes the rhythm of a boolean pattern and pours the values into it (Tidal's `struct`): `structPat("t f t t", "bd")` is a kick on steps 1, 3 and 4. The boolean pattern decides when, the other what.

See also: structure, mask, euclid
