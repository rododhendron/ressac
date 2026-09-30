# Fast 16th arpeggio voice — plucky filter envelope.
# T = test  ·  :w <name> = save as  ·  :dsl = cookbook

@synth :arpdriver (freq=220, sustain=0.12, cutoff=2200) begin
  pulse(:freq, 0.45) |>
  rlpf(:cutoff * (1 + line(2, 0, :sustain)), 0.3) |>
  env_perc(0.001, :sustain)
end
