+++
name = "sample rate"
short = "How many measurements per second a digital signal holds; 44100 or 48000 Hz for audio."
aliases = ["samplerate", "Nyquist"]
tags = ["glossary", "digital"]
examples = []
+++

# sample rate

Nothing above half the sample rate (the Nyquist frequency) can be represented; whatever tries to go there folds back as aliasing. Control-rate signals in SuperCollider (`kr`) run 64 times slower.

See also: aliasing, control rate
