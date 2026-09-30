# Formant-shifted growling bass.
# T = test  ·  :w <name> = save as  ·  :dsl = cookbook

@synth :growlbass (freq=65, sustain=0.6) begin
  saw(:freq) |> band_pass(lfo(3; low=400, high=1800), 0.18) |>
  offset(saw(:freq) |> low_pass(600) |> amp(0.4)) |>
  tanh_drive(1.4)
end
