# Hénon map percussive glitch. Iteration rate = freq → the map fires
# `freq * 4` times per second, producing a harmonically noisy blip.
# Short envelope makes it a percussion-style voice.
#
# NOTE / HAUTEUR : avec a = 1.4 la carte est chaotique, donc apériodique
# — pas de fondamentale, et `n(...)` change la texture, pas la hauteur.
# Pour entendre la mélodie, ramène `a` dans une fenêtre périodique :
#   set(:a, 1.0)   période 4 → hauteur = freq (la note nominale)
#   set(:a, 1.05)  période 8 → une octave plus bas
#   set(:a, 1.25)  période 7 → environ une quinte plus bas
# `rlpf(:freq * 6, 0.4)` à la place du filtre fixe fait suivre le
# spectre à la note. Voir le wiki 03-synth-dsl.
# T = test  ·  :w <name> = save as  ·  :dsl = cookbook

@synth :chaoglitch (freq=440, sustain=0.18, a=1.4, b=0.3) begin
  henon(:freq * 4, :a, :b) |>
  rlpf(2200, 0.4) |>
  env_perc(0.001, :sustain)
end
