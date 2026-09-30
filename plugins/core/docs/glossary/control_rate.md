+++
name = "control rate"
short = "How often a signal is computed: audio rate (`ar`) for what you hear, control rate (`kr`) for slow movements like LFOs and envelopes."
aliases = ["kr", "audio rate", "ar"]
tags = ["glossary", "synthesis"]
examples = []
+++

# control rate

`rate = :kr` on a `ugen` call; `lfo` and `line` are control-rate by nature. A control-rate signal cannot feed an audio input directly, hence `K2A`.

See also: sample rate, LFO, UGen
