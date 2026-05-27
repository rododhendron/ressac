# Linear-congruential pluck. LinCongL can be very pitched at high
# iteration rates — push it through a comb filter at 1/freq and it
# resonates like a damaged Karplus-Strong string.
# T = test  ·  :w <name> = save as  ·  :dsl = cookbook

@synth :chaopluck (freq=220, sustain=1.0, damp=0.5) begin
  lincong(:freq * 64, 1.1, 0.13, 1.0, 0.0) |>
  comb_l(1 / :freq, :sustain, 0.05) |>
  low_pass(:freq * 6) |>
  env_perc(0.001, :sustain) |>
  amp(1.0 - :damp * 0.5)
end
