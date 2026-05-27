@synth :myname (freq=220, cutoff=1200, q=0.3) saw(:freq) |> rlpf(:cutoff, :q)
