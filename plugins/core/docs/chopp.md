+++
examples = ["@d1 :amen |> chopp(8)", "@d1 :amen |> chopp(16) |> rev"]
name = "chopp"
short = "Cuts each event into n consecutive slices of the sample (exported alias of chop)."
tags = ["tidal"]
+++

# chopp

Cuts each event into n consecutive slices of the sample (exported alias of chop).

Cuts every event into n slices of its sample played one after the other: `chopp(4)` on a long vocal turns it into four quick fragments. Exported as `chopp` because `chop` is taken in Julia.

See also: striate, slice, granular
