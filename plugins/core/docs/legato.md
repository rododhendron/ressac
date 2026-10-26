+++
examples = []
name = "legato"
short = "Note overlap (0 = none, 1 = fully held). For tied lines."
tags = ["glossary", "pattern"]
aliases = ["legato/staccato", "staccato"]
+++

# legato

Note overlap (0 = none, 1 = fully held). For tied lines.

How long each note lasts relative to its slot: 1 holds it until the next, 0.2 clips it short, 1.5 lets notes overlap. It sets `sustain` as a fraction of the event length, so it follows the tempo; `sustain` sets seconds.

See also: sustain, legato, envelope
