# ── Mini-notation (inside "…") ──
# bd hh sn hh        — 4 equal events per cycle
# ~                  — rest / silence
# bd*4               — repeat 4 times inside the slot (subdivide)
# bd!3               — same bd in 3 successive slots (no subdivide)
# [bd bd]            — group: 2 events in one slot's time
# <bd sn cp>         — alternate: one per cycle, round-robin
# bd(3,8)            — Euclidean rhythm: 3 hits over 8 steps
# bd:2               — variant index — bd, bd:1, bd:2, ...
# bd@2               — weight: this token gets 2 slots
# combine: <[bd*2] sn> ~ bd ~
