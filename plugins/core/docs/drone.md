+++
examples = ["@d1 :acid |> drone() |> lpf(\"<400 800 1600>\")", "@d1 :pad |> drone() |> set(:freq, \"<110 165>\") |> gain(0.4)"]
name = "drone"
short = "Tient le synth du slot en drone : le pattern module le son vivant au lieu de déclencher des notes."
tags = ["synth", "drone", "modulation"]
+++

# drone

`drone()` marque un slot : son synth utilisateur (un `@synth` du DSL) est
tenu par SuperCollider dans sa variante à porte, et chaque événement du
pattern devient un réglage du nœud vivant (`freq`, `cutoff`, `gain`, tout
argument du `@synth`) plutôt qu'une nouvelle voix. Le pattern est alors
une automation.

- Le premier événement crée le nœud, les suivants le modulent.
- Changer le pattern du slot, le vider (`@d1` seul), le couper (`m`) ou
  `,` (hush) relâchent le nœud avec son `release`.
- La pane MODULATION (`D` dans l'éditeur de synth, ou ouverte à côté)
  montre les drones des slots et permet de les moduler à la main.
- `drone(0)` rend le slot à ses notes.

Seuls les synths du DSL ont une variante à porte ; un sample ou un synth
SuperDirt ignore `drone()`.
