+++
examples = ["@d1 p\"bd*4\" |> lpf(400)             # muffled kick", "@d1 :supersaw |> lpf(p\"<2000 800 4000>\")  # filter sweep across cycles"]
name = "lpf"
short = "Low-pass (Hz). Cuts everything above. <300 = sub only, 5000 = bright."
tags = []
+++

# lpf

Low-pass (Hz). Cuts everything above. <300 = sub only, 5000 = bright.

A low-pass filter keeps what is below its cutoff and darkens the rest. 400 Hz on a kick leaves only the thump; 1200 on a hi-hat loop makes it sit behind the beat; 5000 is barely audible as a filter. Patterning the cutoff (`lpf("<400 800 1600>")`) is the oldest trick in electronic music: a sweep.

`lpf` is SuperDirt's filter, applied to samples and synths alike. Inside a DSL synth, `rlpf` or `low_pass` do the same job with the synth's own signal. `resonance` sharpens the edge of this cutoff.

See also: low-pass filter, cutoff, resonance, hpf
