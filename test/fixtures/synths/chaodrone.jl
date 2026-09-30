# Lorenz attractor drone — slow iteration rate gives a low rumbling
# texture, RLPF tames the high end into a usable bass drone.
# T = test  ·  :w <name> = save as  ·  :dsl = cookbook

@synth :chaodrone (freq=80, sustain=4, cutoff=600) begin
  lorenz(:freq * 6, 10, 28, 8/3, 0.05) |>
  rlpf(:cutoff, 0.3) |>
  tanh_drive(1.2)
end
