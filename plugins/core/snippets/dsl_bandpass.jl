white() |> band_pass(800, 0.25) |> env_perc(0.001, :sustain)
