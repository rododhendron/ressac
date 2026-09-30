+++
examples = ["@d1 :pad |> n(\"0 2 4 6\") |> scale(:minor)", "@d1 :pad |> n(0:7) |> scale(:minor_pentatonic)"]
name = "scale"
short = "Reads the values as degrees of a scale and converts them to semitones."
tags = ["tuning", "glossary", "pitch"]
aliases = ["scales", "mode"]
+++

# scale

Reads the values as degrees of a scale and converts them to semitones.

`scale("minor", "0 2 4")` turns degrees into semitones. Ressac ships equal temperaments (`edo`), just scales built from ratios (`from_ratios`) and stranger ones (Bohlen-Pierce, Fibonacci, Stern-Brocot).

See also: degree, temperament, just intonation, semitone
