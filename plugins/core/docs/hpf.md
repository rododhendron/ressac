+++
examples = ["@d1 p\"oh*8\" |> hpf(6000) |> gain(0.5)   # tight click hat"]
name = "hpf"
short = "High-pass (Hz). Cuts everything below. 200 = removes rumble, 1000 = thin."
tags = []
+++

# hpf

High-pass (Hz). Cuts everything below. 200 = removes rumble, 1000 = thin.

A high-pass filter removes the lows. 200 Hz cleans the mud under a pad or a chord so the kick keeps the floor for itself; 1000 turns a snare into a thin snap; 6000 on an open hat leaves only air. Patterning `hpf` is a cheap way to make a loop breathe.

See also: high-pass filter, lpf, band
