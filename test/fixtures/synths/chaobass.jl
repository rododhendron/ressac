# Logistic-map bass at the chaos threshold. paramA=3.9 sits inside
# the chaotic regime; lowering it toward 3 produces clean cycles
# (drop to 2.8 for a sine-ish tone). The lp + drive shape it into
# something usable as a sub/mid bass.
# T = test  ·  :w <name> = save as  ·  :dsl = cookbook

@synth :chaobass (freq=55, sustain=0.45, drive=1.4) begin
  logistic(:freq * 8, 3.9, 0.5) |>
  low_pass(:freq * 8) |>
  tanh_drive(:drive) |>
  env_perc(0.005, :sustain)
end
