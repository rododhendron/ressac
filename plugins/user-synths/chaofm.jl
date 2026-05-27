# Feedback-sine FM-like timbre. FBSineL combines a sine with a
# self-feedback term: when `im` (index of modulation) and `fb`
# rise, harmonics multiply quickly — full FM-bell at one end,
# clean tone at the other.
# T = test  ·  :w <name> = save as  ·  :dsl = cookbook

@synth :chaofm (freq=220, sustain=1.2, im=1.0, fb=0.1) begin
  fbsine(:freq * 100, :im, :fb, 1.1, 0.5, 0.1, 0.1) |>
  rlpf(:freq * 8, 0.3) |>
  env_perc(0.005, :sustain)
end
