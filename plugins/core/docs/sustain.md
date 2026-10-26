+++
examples = []
name = "sustain"
short = "Level held during the note (0-1). Changes the shape of the ADSR."
tags = []
+++

# sustain

Level held during the note (0-1). Changes the shape of the ADSR.

On a synth with an ADSR, the level held while the note lasts. On a plain event, the duration in seconds that Ressac sends — by default the event's own length, so a `"bd*8"` hit is short and a `"pad"` whole-cycle event is long. `legato` scales that length instead of fixing it.

See also: envelope, ADSR, legato, release
