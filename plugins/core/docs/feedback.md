+++
examples = []
name = "feedback"
short = "Delay or comb feedback (0-0.95). High = long tails / oscillation."
tags = ["glossary", "effects", "synthesis"]
aliases = ["regeneration"]
+++

# feedback

Delay or comb feedback (0-0.95). High = long tails / oscillation.

`delayfeedback` (0-0.95) sets how much of an echo returns; `feedback(fb -> …)` in the DSL wires a loop inside a synth. Ressac's `safe()` limiter keeps runaway feedback from hurting.

See also: delay, comb filter, resonance
