+++
examples = []
name = "release"
short = "Fade-out time after the note ends (s). 0.1 = staccato, 0.5 = normal, 2 = long tail."
tags = []
+++

# release

Fade-out time after the note ends (s). 0.1 = staccato, 0.5 = normal, 2 = long tail.

How long the sound keeps ringing after the event ends, in seconds. 0.05 is dry, 0.5 natural, 2 a long tail. Long releases pile up on fast patterns; `cut` or `mono` keep voices from stacking.

See also: envelope, ADSR, sustain, cut
