+++
examples = ["@d1 p\"sn\" |> delay(0.6) |> delaytime(0.375) |> delayfeedback(0.5)"]
name = "delay"
short = "Delay send. 0 = dry, 1 = wet."
tags = ["glossary", "effects"]
aliases = ["delay line"]
+++

# delay

Delay send. 0 = dry, 1 = wet.

How much goes to the delay line: 0 none, 1 as loud as the source. `delaytime` sets the echo spacing in beats (0.375 is a dotted eighth at 4 beats per cycle), `delayfeedback` how many echoes you hear. A short, quiet delay thickens; a long one with feedback becomes a rhythm of its own.

See also: delay, delaytime, delayfeedback, stut
