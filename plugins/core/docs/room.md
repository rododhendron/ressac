+++
examples = ["@d1 p\"cp\" |> room(0.8) |> gain(0.6)"]
name = "room"
short = "Reverb send. 0 = dry, 1 = wet. Goes through SuperDirt's room reverb."
tags = []
+++

# room

Reverb send. 0 = dry, 1 = wet. Goes through SuperDirt's room reverb.

How much of the sound goes to SuperDirt's reverb. 0.3 adds a sense of place, 0.8 drowns a clap in space. Pair it with `size` for the room's dimensions and `dry` to keep the direct signal. Each slot has its own reverb (its orbit), so a wet clap does not smear the kick.

See also: reverb, size, dry, orbit
