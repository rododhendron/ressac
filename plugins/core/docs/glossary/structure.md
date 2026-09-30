+++
name = "structure"
short = "Which side decides when events happen when two patterns are combined."
aliases = ["rhythmic structure"]
tags = ["glossary", "pattern"]
examples = []
+++

# structure

By default the left side (the sound) keeps its rhythm and reads the control at each onset — Tidal's `#`. `both` cuts events at every change on either side, `sampled` forces the left side even for a rhythm-less sound. Only `mask`, `structPat`, `sew` take the structure from a boolean pattern.

See also: pattern, onset, event
