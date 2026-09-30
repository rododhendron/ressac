+++
examples = ["@d1 :acid |> drone() |> lpf(\"<400 800 1600>\")", "@d1 :pad |> drone() |> set(:freq, \"<110 165>\") |> gain(0.4)"]
name = "drone"
short = "Holds the slot's synth as a drone: the pattern modulates the live sound instead of triggering notes."
tags = ["synth", "drone", "modulation", "glossary", "ressac"]
aliases = ["drones"]
+++

# drone

Holds the slot's synth as a drone: the pattern modulates the live sound instead of triggering notes.

`D` in the synth editor starts one; the MODULATION pane shows its arguments; `drone()` on a slot lets a pattern modulate it. Under the hood it is a gated variant of the synth.

See also: gate (envelope), modulation, SynthDef
