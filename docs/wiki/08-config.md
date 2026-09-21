# Configuration et thèmes

## `ressac.toml`

Fichier de configuration à la racine du projet, chargé par `live()` et
rechargeable en session avec `:reload-config`. Toutes les clés sont
optionnelles ; valeurs par défaut ci-dessous.

```toml
[ui]
theme = "cyberpunk"   # un thème intégré ou personnalisé
fps   = 60

[input]
t_hold_initial_ms = 250
t_hold_min_ms     = 60
t_hold_accel      = 0.85

nudge_int_small   = 1
nudge_int_big     = 10
nudge_float_small = 1.0
nudge_float_big   = 0.1

[scope]
scope_zoom_step = 1.5
scope_zoom_max  = 32.0
```

## Thèmes

Changer en live : `:theme <nom>`. Lister : `:theme` seul.

**Thèmes Ressac :**
- `cyberpunk` — magenta chaud + cyan électrique sur noir
- `solarpunk` — sauge + or + vert forêt sur crème

**Intégrés à Tachikoma (sombres) :**
kokaku · esper · motoko · kaneda · neuromancer · catppuccin ·
solarized · dracula · outrun · zenburn · iceberg

**Intégrés à Tachikoma (clairs) :**
paper · latte · solaris · sakura · ayu · gruvbox · frost ·
meadow · dune · lavender · horizon · overcast · dusk

Le thème par défaut se règle dans `ressac.toml`, `[ui] theme = ...`.

## Accélération de T maintenu

Maintenir `t` / `T` / `Espace` sur une pane synth rejoue le synth de
plus en plus vite. Intervalle initial = `t_hold_initial_ms` (250 ms),
chaque tir multiplie par `t_hold_accel` (0.85) jusqu'à `t_hold_min_ms`
(60 ms). Donc ~4 tirs/s qui montent à ~17 tirs/s en deux secondes.

Règle ça dans `ressac.toml` pour une rampe plus lente ou plus nerveuse.

## Chaîne de sécurité

Active par défaut au démarrage de SC :

- **LeakDC** — enlève la composante continue (un oscillateur bloqué en
  bas peut abîmer des enceintes sans produire de son audible).
- **HPF 10 Hz** — coupe les infrasons. Sous l'audition humaine, mais
  laisse le sub musical (15-25 Hz) intact.
- **Limiteur à 0.95** — plafond true-peak. Empêche un feedback ou une
  pile d'oscillateurs d'exploser les tympans.
- **Fondu de 80 ms** au démarrage pour que les premières trames ne
  claquent pas.

Bascule avec `:safety on|off`.

## Journal

`:log` bascule la hauteur du journal en bas de l'écran : 3 lignes (par
défaut) → 10 → replié → 3. `:log N` fixe une hauteur. `:copylogs` copie
tout le journal dans le presse-papier, `:vsplit log` l'ouvre dans une
pane à part.
