+++
examples = []
name = "attack"
short = "Time to reach full volume after the trigger (s). 0.01 = instant, 0.5 = soft fade-in."
tags = []
+++

# attack

Time to reach full volume after the trigger (s). 0.01 = instant, 0.5 = soft fade-in.

How long the sound takes to reach full volume after it starts, in seconds. 0.001 is a click, 0.05 softens a pluck, 0.5 is a slow pad swell. Long attacks on short events never reach their peak: match it to `sustain`.

See also: envelope, ADSR, release
