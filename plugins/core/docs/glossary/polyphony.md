+++
name = "polyphony"
short = "Whether several notes can sound at once (polyphonic) or a new one silences the previous (monophonic)."
aliases = ["polyphonic", "monophonic"]
tags = ["glossary", "synthesis"]
examples = []
+++

# polyphony

Ressac's synths are polyphonic by default: every event is a fresh voice that ends with its envelope. `mono` drops overlapping events; `cut` groups voices that cut each other.

See also: node, envelope
