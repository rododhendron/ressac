@synth :acid (freq=80, cutoff=2000, envmod=4) saw(:freq) |>
    rlpf(:cutoff * (1 + :envmod), 0.3)
