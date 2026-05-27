# ╭─ chaos generators — modify any value to hear the effect ─╮
# │  Each Chaos.* returns a Pattern{Float64} plugged into
# │  set(:k, …). Compose with range_pat / segment / slow / fast.
# ╰────────────────────────────────────────────────────────────╯
cps!(0.5)

# ── Lorenz attractor (3D continuous) ──────────────────────
# σ ρ β = strength of each axis coupling (canonical chaos: 10/28/8÷3)
#   try ρ=14 → stable orbit, ρ=99 → wider chaos
# dt    = Euler step (smaller = smoother, slower)
# axis  = :x (-25..25)  :y (-30..30)  :z (0..60)
# steps_per_cycle = sampling rate within one Ressac cycle
# init  = (x₀, y₀, z₀) initial state
@d1 :supersaw |> n(p"0 3 5 7") |> set(:cutoff,
    Chaos.lorenz(σ=10, ρ=28, β=8/3, dt=0.01, axis=:x,
                  steps_per_cycle=100, init=(0.1, 0.0, 0.0))
    |> range_pat(400, 4000)) |> gain(0.5)

# ── Hénon map (2D discrete) — sharp, glitchy ───────────────
# a b   = canonical chaos a=1.4 b=0.3 ; a=1.06 = periodic
# axis  = :x (-1.5..1.5) or :y
@d2 p"bd ~ sn ~" |> set(:speed,
    Chaos.henon(a=1.4, b=0.3, axis=:x,
                 steps_per_cycle=64, init=(0.1, 0.0))
    |> range_pat(0.9, 1.2))

# ── Logistic map (1D) — r selects regime ───────────────────
# r ∈ (0,4]: r<3 = fixed point ; r=3..3.57 = period doubling
#            r>3.57 = chaos ; r=3.83 = period-3 window ; r=4 = max chaos
# init must be in (0, 1) strictly
@d3 :super808 |> n(p"<-12 -10 -8 -10>") |> set(:pan,
    Chaos.logistic(r=3.9, steps_per_cycle=64, init=0.5)
    |> range_pat(-0.8, 0.8)) |> release(0.6) |> gain(1.2)

# ── Rössler attractor (3D continuous) — smoother loop ──────
# a b c = a=0.2 b=0.2 c=5.7 chaotic ; c=2 stable spiral
# (uncomment to add a 4th voice)
# @d4 :superpiano |> n(p"0 7 12") |> set(:speed,
#     Chaos.rossler(a=0.2, b=0.2, c=5.7, dt=0.05, axis=:x,
#                    steps_per_cycle=100, init=(0.1, 0.0, 0.0))
#     |> range_pat(0.8, 1.5)) |> gain(0.5)

# ── Standard map (Chirikov) — area-preserving ──────────────
# K     = K≈0.971635 is the KAM threshold (just-chaotic)
# axis  = :p (momentum, unbounded) or :θ (angle [0, 2π))
# (uncomment to add a 5th voice)
# @d5 :superhammond |> n(p"<0 5 7 12>") |> set(:gain,
#     Chaos.standard(K=0.971635, axis=:p,
#                     steps_per_cycle=64, init=(0.1, 0.1))
#     |> range_pat(0.3, 0.9))

# ── Anchor ─────────────────────────────────────────────────
@d9 p"hh*8" |> gain(0.2) |> hpf(4000)