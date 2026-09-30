+++
name = "FM"
short = "Modulating the frequency of one oscillator with another at audio rate: bells, electric pianos, metallic tones."
aliases = ["frequency modulation", "fm synthesis"]
tags = ["glossary", "synthesis"]
examples = []
+++

# FM

`sin_osc(:freq + sin_osc(:freq * 2) * 200)` is a two-operator FM voice. `modfreq` and `moddepth` set the modulator on FM presets; the depth (index) usually drops over the note.

See also: modulation, ring modulation, harmonic
