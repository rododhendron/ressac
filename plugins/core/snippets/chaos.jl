# Chaos-driven modulation — control-rate Pattern{Float64}
# generators piped into SuperDirt params.
cps!(0.5)

# Hénon map glitches the kick speed every step
@d1 p"bd ~ sn ~" |> set(:speed, Chaos.henon() |> range_pat(0.9, 1.2))

# Lorenz attractor sweeps a supersaw filter
@d2 :supersaw |> n(p"0 3 5 7") |> set(:cutoff, Chaos.lorenz() |> range_pat(400, 3500)) |> gain(0.6)

# Logistic map (chaos edge) pans a sub
@d3 :super808 |> n(p"<-12 -10 -8 -10>") |> set(:pan, Chaos.logistic(r=3.95) |> range_pat(-0.8, 0.8)) |> release(0.6) |> gain(1.2)