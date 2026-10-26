+++
examples = ["@d1 p\"bd*4\" |> gain(0.8)", "@d1 p\"hh hh hh hh\" |> gain(p\"0.8 0.4 0.6 0.4\")  # accent pattern", "@d1 p\"sn\" |> gain(0.7) |> gain(1.4)             # composes ×, becomes 0.98"]
name = "gain"
short = "Volume multiplier. 1 = unity, 0.5 = half, 2 = double. Composes by ×."
tags = []
+++

# gain

Volume multiplier. 1 = unity, 0.5 = half, 2 = double. Composes by ×.

Volume is multiplicative here: `gain(0.5)` halves the amplitude, `gain(2)` doubles it, and two gains in a chain multiply (`gain(0.7) |> gain(1.4)` is 0.98). A gain pattern is the simplest way to write accents: the loud hits are the ones that get the bigger number.

Above 1 the sound clips at the output; Ressac's safety chain limits it, but a dense mix sounds better with every voice under 1 and the kick around 0.9.

See also: amplitude, velocity, pump, mixer
