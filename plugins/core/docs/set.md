+++
examples = ["@d1 :bd |> set(:cut, 1)", "@d1 :amen |> set(:begin, 0.25) |> set(:end, 0.5)"]
name = "set"
short = "Sets any SuperDirt parameter that has no dedicated helper."
tags = ["control"]
+++

# set

Sets any SuperDirt parameter that has no dedicated helper.

Sets any SuperDirt parameter by name, for the ones without a helper: `set(:cutoff, "<400 800>")`. The second argument can be a number, a string of mini-notation or a pattern. A control pattern keeps the left structure by default; see `both` and `sampled`.

See also: structure, both, sampled
