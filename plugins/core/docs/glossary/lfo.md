+++
name = "LFO"
short = "An oscillator too slow to hear, used to move another parameter: wobble, tremolo, vibrato."
aliases = ["low-frequency oscillator", "lfo"]
tags = ["glossary", "synthesis", "modulation"]
examples = []
+++

# LFO

`lfo(0.5; low = 400, high = 2000)` in the DSL sweeps a cutoff twice per second… well, once every two seconds. `rate`, `depth` and `centre` describe it on a pattern. Any signal pattern (`sine`, `saw`) is an LFO at cycle speed.

See also: modulation, tremolo, vibrato, oscillator
