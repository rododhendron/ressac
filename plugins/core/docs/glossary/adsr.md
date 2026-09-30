+++
name = "ADSR"
short = "The four stages of a classic envelope: Attack, Decay, Sustain, Release."
aliases = ["adsr"]
tags = ["glossary", "synthesis"]
examples = []
+++

# ADSR

Attack is the time to reach the peak, decay the fall to the sustain level, sustain the level held while the note lasts, release the fade after it ends. `env_adsr(0.01, 0.2, 0.6, 0.5)` in the DSL; `attack`, `decay`, `sustain`, `release` as SuperDirt controls.

See also: envelope, attack, decay, sustain, release
