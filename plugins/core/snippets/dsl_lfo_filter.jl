@synth :wobble (freq=80, rate=4) saw(:freq) |>
    rlpf(lfo(:rate; low=300, high=2400), 0.4)
