+++
name = "just intonation"
short = "Tuning built on whole-number frequency ratios (3:2 for a fifth), so intervals beat as little as possible."
aliases = ["just", "pure interval"]
tags = ["glossary", "pitch"]
examples = []
+++

# just intonation

Pure ratios sound calm and resonant but do not fit an evenly divided octave. `from_ratios([1, 9//8, 5//4, 3//2, 2])` registers such a scale; `semitones(3//2)` gives the just fifth in semitones.

See also: temperament, harmonic series, cent
