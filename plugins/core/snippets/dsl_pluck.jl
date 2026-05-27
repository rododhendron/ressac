@synth :pluck (freq=220) white() |> env_perc(0, 0.005) |>
    delay_c(1 / :freq) |> low_pass(:freq * 4)
