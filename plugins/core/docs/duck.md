+++
examples = ["@d2 :bass |> n(\"0 3\") |> duck(\"bd(3,8)\")", "@d2 :pad |> duck(\"bd*4\"; depth = 0.9, release = 1//16)"]
name = "duck"
short = "Sidechain driven by a real pattern: the gain dips on every onset of the trigger, then recovers."
tags = ["mix"]
+++

# duck

Sidechain driven by a real pattern: the gain dips on every onset of the trigger, then recovers.

Ducks the gain on every onset of another pattern and lets it recover: `duck("bd*4")` on a bass is the kick/bass sidechain. `pump` fakes it without a trigger.

See also: sidechain, pump, gain
