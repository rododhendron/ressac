# Latoocarfian noisy-buzz pad. Heavy filtering + reverb turn the
# raw chaotic buzz into a moving, slowly-detuning textural pad.
# T = test  ·  :w <name> = save as  ·  :dsl = cookbook

@synth :chaopad (freq=220, sustain=4) (auto_env=false,) begin
  latoo(:freq * 16, 1.0, 3.0, 0.5, 0.5, 0.5, 0.5) |>
  low_pass(lfo(0.18; low=600, high=2200)) |>
  free_verb(0.5, 0.92, 0.6) |>
  amp(0.35)
end
