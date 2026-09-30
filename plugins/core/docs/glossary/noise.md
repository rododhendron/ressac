+++
name = "noise"
short = "A signal with no pitch: all frequencies at once. Wind, hiss, the body of a snare."
aliases = ["white noise", "pink noise", "brown noise"]
tags = ["glossary", "synthesis"]
examples = []
+++

# noise

White noise has equal energy everywhere and sounds harsh; pink noise rolls off the highs (natural, rain-like); brown noise is deeper still. `white()`, `pink()`, `brown()` in the DSL, usually followed by a filter and a short envelope for percussion.

See also: filter, envelope, oscillator
