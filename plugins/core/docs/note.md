+++
examples = ["@d1 :pad |> note(\"0 3 7\")", "@d1 :cb |> note(\"0 12\")"]
name = "note"
short = "Transposes in semitones (alias up). On a SuperDirt sample, changes the playback speed."
tags = ["control"]
+++

# note

Transposes in semitones (alias up). On a SuperDirt sample, changes the playback speed.

Transposes in semitones, like `n` on a synth. On a SuperDirt sample it changes the playback speed, so a drum pitched up also gets shorter. `note("c e g")` accepts note names; `up` is Tidal's alias.

See also: n, speed, pitch
