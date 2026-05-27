@synth :kick (sustain=0.4) sin_osc(line(120, 40, 0.05)) |>
    env_perc(0.001, :sustain) |>
    offset((white() |> env_perc(0, 0.005)) * 0.5)
