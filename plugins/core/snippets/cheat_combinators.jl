# ── Combinators (pattern transforms) ──
# pure(:bd)                  — pattern firing :bd once per cycle
# silence(Symbol)            — empty pattern (placeholder)
# fast(2, p)  /  p |> fast(2)        — ×2 speed
# slow(2, p)  /  p |> slow(2)        — ÷2 speed (dilate)
# density(2, p)              — alias for fast
# rev(p)                     — reverse events within each cycle
# every(4, fast(2), p)       — apply fast(2) every 4th cycle
# every(4, rev, p)           — reverse every 4th cycle
# stack(p, q, r)             — play patterns in parallel
# cat([p, q, r])             — alternate one per cycle
# mask(p, q::Pattern{Bool})  — gate p by q (true = let through)
# gate(:bd, "1 0 1 1")      — substitute :bd for every "1" event
# degree(x)                  — note as scale degree (set :scale first)
# n(x)                       — sample variant index OR semitone offset
