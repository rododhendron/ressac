+++
examples = ["@d1 p\"bd*2\" |> speed(0.5)           # pitched down + slower", "@d1 p\"vinyl\" |> speed(p\"1 0.95 1 1.05\")  # turntable wow"]
name = "speed"
short = "Playback speed. 0.5 = an octave down and slower, 2 = an octave up and faster. Composes by ×."
tags = ["glossary", "sound"]
aliases = ["playback speed"]
+++

# speed

Playback speed. 0.5 = an octave down and slower, 2 = an octave up and faster. Composes by ×.

The playback rate of a sample. 2 is an octave up and twice as short, 0.5 an octave down and twice as long, -1 plays it backwards. Composes by multiplication like `gain`. A tiny wobble (`speed("1 0.98 1 1.02")`) is a cheap turntable feel; `hurry` changes speed and tempo together.

See also: sample, octave, hurry, loopAt
