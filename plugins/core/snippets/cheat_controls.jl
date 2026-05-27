# ── Controls (chain with |>) ──
# gain(0.8)        — volume multiplier        (composes ×)
# pan(0.3)         — stereo position          (last write wins)
# speed(0.5)       — sample playback rate     (composes ×)
# lpf(2000)        — low-pass cutoff Hz       (composes min — strictest wins)
# hpf(200)         — high-pass cutoff Hz      (composes max)
# n("0 3 5")      — sample variant / semitones (overwrite)
# room(0.4)        — reverb send 0..1
# delay(0.4)       — delay send 0..1
# delaytime(0.25)  — delay time in beats (¼ = 16th note at 4 cps)
# delayfeedback(0.5)
# shape(0.2)       — waveshaper drive
# attack / release / sustain / hold — envelope shape per note
# cutoff / resonance — synth-internal filter
# vowel(:a/:e/:i/:o/:u)  — formant filter
# crush(8) / coarse(4)   — bit-crush / sample-rate reduce
# accelerate(2) — pitch sweep semis/sec
# set(:any_key, val)     — override any OSC param verbatim
