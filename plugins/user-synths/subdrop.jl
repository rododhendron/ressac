# Pure sub-bass with pitch drop.
# T = test  ·  :w <name> = save as  ·  :dsl = cookbook

@synth :subdrop (freq=40, sustain=0.9) begin
  sin_osc(line(90, :freq, 0.4)) |> env_linen(0.005, :sustain, 0.1)
end
