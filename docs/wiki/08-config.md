# Configuration et thèmes

## `ressac.toml`

Fichier de configuration à la racine du projet, chargé par `live()` et
rechargeable en session avec `:reload-config`. Toutes les clés sont
optionnelles ; valeurs par défaut ci-dessous.

```toml
[ui]
theme = "cyberpunk"   # un thème intégré ou personnalisé
fps   = 60
keyboard = "auto"     # auto (détection), azerty, qwerty — voir plus bas
hover = true          # bulle de glossaire au survol de la souris
hover_lock_ms = 3000  # délai avant que la bulle se verrouille

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

## Sorties audio et casque

`:sorties` liste les sorties que PipeWire connaît — enceintes, casque
filaire, casque Bluetooth — et branche SuperCollider dessus.

| Touche | Ce qu'elle fait |
|---|---|
| `Entrée` | la ligne devient la **sortie principale** (◉) |
| `c` | la ligne devient le **casque** (◎) ; `c` de nouveau : plus de casque |
| `p` | ce que j'essaie : dans le casque seulement / partout (aussi `:casque`) |
| `r` | relire les sorties (un casque qu'on vient d'allumer) |

SuperCollider sort quatre canaux : 1-2 vont à la sortie principale, 3-4 au
casque. **Le casque entend la sortie principale**, toujours. Avec `p`
(ou `:casque`), ce qu'on *essaie* — `T`, les propositions de l'atelier
(`o`, `cim`), l'écoute d'un candidat de l'explorateur, d'un son de la
réserve — ne sort **que dans le casque** : on cherche au casque pendant que
la sortie continue de jouer ce qui était gardé. Garder (`Entrée` dans
l'atelier, `:w`, évaluer une ligne) fait passer le son sur la sortie. La
barre d'état rappelle `casque`, ou `casque · essais`.

Ce qui joue pour de bon (les patterns, un drone, une boucle qu'on frappe)
va toujours à la sortie principale. `:rec` n'enregistre qu'elle.

Le réglage est gardé (`audio.toml`, avec les préférences) et rebranché
quand SuperCollider se met à répondre. Un casque **Bluetooth** a du
retard (souvent 0,1 à 0,2 s) : bon pour chercher un timbre, pas pour caler
un rythme à l'oreille. Si une sortie a disparu, `:sorties` le dit ; `r`
relit.

Il faut que SuperCollider ait été lancé avec ses quatre sorties — c'est le
cas de `scripts/superdirt-startup.scd` (`RESSAC_OUT_CHANNELS=2` revient à
deux). Sans PipeWire (`pw-dump`, `pw-link`), `:sorties` le dit et ne fait
rien.

## Journal

`:log` bascule la hauteur du journal en bas de l'écran : 3 lignes (par
défaut) → 10 → replié → 3. `:log N` fixe une hauteur. `:copylogs` copie
tout le journal dans le presse-papier, `:vsplit log` l'ouvre dans une
pane à part.

## Disposition du clavier

Quand le terminal parle le protocole clavier kitty avec les « touches
alternatives » (kitty, foot, wezterm, ghostty, alacritty récents), il
envoie le caractère que Maj produit vraiment et tout marche. Sinon
Ressac reçoit la touche de base avec Maj et doit savoir quoi en faire :
sur un AZERTY, Maj+`,` est `?`, pas `<`.

`keyboard = "auto"` détecte, dans l'ordre : la variable `RESSAC_KEYBOARD`,
cette clé, `XKB_DEFAULT_LAYOUT`, `localectl status` (fiable, y compris
sous Wayland), `setxkbmap -query` (X11 seulement), puis `LANG` (`fr`,
`be` → azerty). Le journal dit ce qui a été choisi au démarrage ;
`:keyboard azerty`, `:keyboard qwerty` ou `:keyboard auto` changent en
session, `:keyboard` seul affiche l'état.

## Glossaire au survol

Les fiches et le glossaire (`plugins/core/docs`, en anglais) reconnaissent
leurs termes dans tout texte affiché : ils sont soulignés. Poser la souris
sur un terme ouvre une bulle avec sa définition ; elle se verrouille au bout
de `hover_lock_ms` millisecondes, ou dès que la souris y entre. Verrouillée,
elle laisse survoler ses propres termes, qui ouvrent chacun une bulle à côté.
Sortir de toutes les bulles ferme tout ; `Esc` ou n'importe quelle touche
aussi. `hover = false` coupe le mécanisme (et le suivi de la souris dans le
terminal, mode 1003).
