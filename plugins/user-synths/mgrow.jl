# Formant-shifted growling bass.
# T = test  ·  :w <name> = save as  ·  :dsl = cookbook

@synth :mgrow (freq=70, sustain=0.3) begin
  saw(:freq) |> band_pass(lfo(14; low=220, high=1200), 0.58) |>
  offset(saw(:freq) |> low_pass(400) |> amp(0.7)) |>
  tanh_drive(1.2)
end
