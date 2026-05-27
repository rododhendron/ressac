# Hénon map percussive glitch. Iteration rate = freq → the map fires
# `freq` times per second, producing a pitched but harmonically noisy
# blip. Short envelope makes it a percussion-style voice.
# T = test  ·  :w <name> = save as  ·  :dsl = cookbook

@synth :chaoglitch (freq=440, sustain=0.18, a=1.4, b=0.3) begin
  henon(:freq * 4, :a, :b) |>
  rlpf(2200, 0.4) |>
  env_perc(0.001, :sustain)
end
