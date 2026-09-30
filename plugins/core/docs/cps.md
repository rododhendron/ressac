+++
examples = ["cps!(0.5)        # 30 BPM at 4 beats/cycle, default", "cps!(0.75)       # ~45 BPM", ":bpm             # tap-tempo: 4 hits + Enter sets cps live"]
name = "cps"
short = "Cycles per second — Ressac's tempo unit. 0.5 = 1 cycle / 2 s (30 BPM at 4 beats per cycle), 0.8 ≈ 48 BPM, 0.3 = 18 BPM. cps!(x) sets it live, :cps x from the TUI."
tags = ["glossary", "pattern"]
aliases = ["cycles per second", "tempo", "BPM"]
+++

# cps

Cycles per second — Ressac's tempo unit. 0.5 = 1 cycle / 2 s (30 BPM at 4 beats per cycle), 0.8 ≈ 48 BPM, 0.3 = 18 BPM. cps!(x) sets it live, :cps x from the TUI.

`cps!(0.6)` sets it live; `:bpm` taps it. `secs(0.25)` converts real time to cycles at the current cps.

See also: cycle, pattern
