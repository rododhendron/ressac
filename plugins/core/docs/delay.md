+++
examples = ["@d1 p\"sn\" |> delay(0.6) |> delaytime(0.375) |> delayfeedback(0.5)"]
name = "delay"
short = "Delay send. 0 = dry, 1 = wet."
tags = ["glossary", "effects"]
aliases = ["delay line"]
+++

# delay

Delay send. 0 = dry, 1 = wet.

`delay`, `delaytime`, `delayfeedback` on a pattern send to SuperDirt's delay; `delay_c`, `comb_c` in the DSL build one inside the synth. `stut` and `echo` make echoes out of pattern events instead of audio.

See also: feedback, comb filter, reverb
