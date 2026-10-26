+++
examples = []
name = "cutoff"
short = "Frequency of the synth's internal filter (Hz). Lower = darker."
tags = ["glossary", "synthesis", "effects"]
aliases = ["cutoff frequency", "corner frequency"]
+++

# cutoff

Frequency of the synth's internal filter (Hz). Lower = darker.

The frequency where the synth's own low-pass starts to act, in Hz. Lower is darker. Sweep it with a pattern (`cutoff("<400 800 1600 800>")`) for the classic acid line, or with an LFO on a drone. In the DSL it is whatever argument you feed to `rlpf`.

See also: low-pass filter, resonance, lpf
