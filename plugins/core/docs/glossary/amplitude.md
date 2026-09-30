+++
name = "amplitude"
short = "How big the signal is — what you hear as volume."
aliases = ["loudness", "level"]
tags = ["glossary", "sound"]
examples = []
+++

# amplitude

A signal swings between -1 and 1; amplitude is the size of that swing. `gain` multiplies it (0.5 = half, 2 = double), the envelope shapes it over the note. Past 1.0 the output clips: Ressac's `safe()` limiter catches that at the end of every chain.

See also: gain, envelope, clipping, decibel
