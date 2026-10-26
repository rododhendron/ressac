+++
examples = ["@d1 :pad |> n(\"0 2 4 6\") |> scale(:minor)", "@d1 :pad |> n(0:7) |> scale(:minor_pentatonic)"]
name = "scale"
short = "Reads the values as degrees of a scale and converts them to semitones."
tags = ["tuning", "glossary", "pitch"]
aliases = ["scales", "mode"]
+++

# scale

Reads the values as degrees of a scale and converts them to semitones.

Reads the values of a pattern as degrees of a scale and converts them to semitones: `scale("minor", "0 2 4 7")`. Ressac's scales include the usual modes, equal temperaments (`edo`) and just scales built from ratios.

See also: scale, degree, toScale, semitone
