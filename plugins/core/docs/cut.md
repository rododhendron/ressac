+++
examples = []
name = "cut"
short = "Cut group: voices sharing the same positive integer cut each other off."
tags = []
+++

# cut

Cut group: voices sharing the same positive integer cut each other off.

A cut group: when a new voice starts in group 1, every playing voice of group 1 stops. The classic use is an open hi-hat silenced by the closed one: `"oh*2 hh*6" |> cut(1)`.

See also: mono, release, polyphony
