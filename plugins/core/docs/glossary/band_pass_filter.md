+++
name = "band-pass filter"
short = "Keeps only a window of frequencies (band-pass) or removes only that window (band-reject, notch)."
aliases = ["band-pass", "bandpass", "BPF", "band-reject", "notch"]
tags = ["glossary", "synthesis", "effects"]
examples = []
+++

# band-pass filter

`bandf` and `bandq` set the window on a pattern; `band_pass(freq, q)` in the DSL. `band(40, 250)` uses a high-pass then a low-pass to give each voice its own frequency room.

See also: filter, cutoff, resonance
