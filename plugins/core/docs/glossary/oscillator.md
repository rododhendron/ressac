+++
name = "oscillator"
short = "The part of a synth that produces a repeating waveform at a given frequency — the raw material."
aliases = ["osc", "oscillators"]
tags = ["glossary", "synthesis"]
examples = []
+++

# oscillator

`sin_osc(:freq)`, `saw(:freq)`, `pulse(:freq, 0.5)` are oscillators; noise generators (`white`, `pink`) are their unpitched cousins. Everything else in a chain shapes what they produce.

See also: waveform, LFO, noise
