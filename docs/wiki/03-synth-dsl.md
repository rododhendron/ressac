# DSL de synthèse — Julia → SuperCollider

Le DSL décrit un SynthDef comme une expression Julia enchaînée par des
pipes, compilée en SC au chargement. Chargé dans Main automatiquement,
pas de `using` nécessaire.


> **Dans un pattern** : `@d1 :monsynth |> n("0 4 7")` pilote `freq` du
> SynthDef (`n`/`note`/`octave`/`midinote` → fréquence, note 0 = do 5) et
> sa durée suit l'événement si le SynthDef déclare `sustain`. Déclare donc
> `freq` et `sustain` dans les paramètres pour qu'un synth réponde aux
> notes et au rythme. Un `.scd` brut est lu de la même façon : ses
> arguments (`|out = 0, freq = 110, amp = 0.5|` ou `arg freq = 440;`)
> deviennent ses paramètres. Si la hauteur ne s'appelle pas `freq`,
> déclare-la dans `plugin.toml` : `[synths.monsynth] pitch = "midinote"`
> (ou `"note"`, ou n'importe quelle clé en hertz).
>
> Le titre de la pane le montre : `SYNTH · monsynth · hauteur freq ·
> durée sustain`, ou `sans hauteur`. `:note c4` (ou `:note 7`, `:note
> off`) fixe la note que `T` joue en audition ; sans `:note`, `T` joue
> les défauts du SynthDef.

## Minimal — 3 mots

```julia
@synth :bare saw(:freq)
```

Remplit `freq=220, sustain=0.5, gain=0.5`, ajoute une enveloppe
`Env.linen(0.01, sustain, 0.1)`, multiplie par `:gain` et route par
DirtPan. Le SC compilé part vers SuperCollider par le même chemin OSC
que `T`.

## Paramètres explicites

```julia
@synth :acid (freq=80, cutoff=2000, q=0.3)
    saw(:freq) |> rlpf(:cutoff, :q) |> tanh_drive(1.5)
```

Les symboles (`:freq`, `:cutoff`) deviennent des arguments SC : on les
pilote en live depuis les patterns : `@d1 :acid |> n("0 3 5")`.

## Drones — tenir un son et le moduler en direct

Un synth du DSL a toujours un jumeau **à porte** (`<nom>_drone`) : la même
chaîne, tenue tant que `gate` vaut 1, relâchée en `release` secondes.
C'est lui qu'on entend en drone, et chaque argument du `@synth` devient un
knob vivant.

Depuis l'éditeur de synth :

| Touche | Effet |
|---|---|
| `D` | lance le synth en drone et ouvre la pane MODULATION à côté ; `D` de nouveau le relâche |
| `T` | pendant qu'un drone tourne : réévalue le texte, nouveau nœud, réglages gardés |
| `:note c4` | la hauteur de départ du drone (comme pour T) |

Dans la pane MODULATION (un argument par ligne, `●` = la valeur, `┼` = le
défaut du synth) :

| Touche | Effet |
|---|---|
| `j` / `k` | argument suivant / précédent |
| `h` / `l` | moduler − / + (24 pas par octave pour les fréquences, linéaire sinon) ; `H` / `L` par grands pas |
| `=` puis `⏎` | saisir une valeur exacte |
| `0` | revenir au défaut |
| `Tab` | drone suivant quand plusieurs tournent |
| `x` / `X` | relâcher ce drone / tous |
| molette | module l'argument survolé ; clic le focalise |

Une enveloppe écrite à la main (`env_perc`, `env_adsr`…) garde sa forme en
drone mais ne libère plus le nœud : c'est la porte qui s'en charge. Un son
percussif s'éteint donc de lui-même — c'est sa nature — tandis qu'un
`env_adsr(...; gate = :gate)` tient et se relâche proprement.

Côté PLAY, `drone()` marque un slot : le premier événement crée le nœud,
les suivants le **modulent** au lieu de déclencher une voix. Le pattern est
alors une automation du son vivant, et le slot apparaît dans la pane
MODULATION où on peut aussi le régler à la main.

```julia
@d1 :acid |> drone() |> lpf("<400 800 1600>") |> set(:freq, "<55 110>")
```

Changer le pattern du slot, le vider (`@d1` seul), le couper (`m`) ou `,`
(hush) relâchent le nœud avec son `release`. `!` (panic) coupe tout.

Sans passer par la porte, un synth peut aussi tenir seul en désactivant
l'enveloppe automatique :

```julia
@synth :pad (freq=110, sustain=999) (auto_env=false,)
    saw(:freq) |> low_pass(800) |> stereo_pan(0)
```

## Les UGens disponibles

| Catégorie  | Exemples                                                          |
| ---------- | ----------------------------------------------------------------- |
| Osc        | `saw sin_osc pulse tri square var_saw blip formant`               |
| Bruit      | `white pink brown gray dust crackle lf_noise0/1/2`                |
| Chaos      | `lorenz henon logistic standard_map latoo lincong quad fbsine gbman cusp` |
| LFOs       | `lfo lfo_saw lfo_tri lfo_pulse lf_cub lf_par`                     |
| Rampes     | `line x_line ramp_kr lag_kr/2/3`                                  |
| Filtres    | `low_pass high_pass band_pass band_reject rlpf rhpf moog_ff`      |
| Réverb     | `free_verb g_verb decay decay2`                                   |
| Delays     | `delay_n/l/c comb_n/l/c allpass_n/l/c`                            |
| Modulation | `chorus flanger phaser`                                           |
| Granulaire | `grain_buf warp1`                                                 |
| Stéréo     | `stereo_pan stereo_balance stereo_rotate splay mix_sigs`          |
| Mise en forme | `tanh_drive soft_clip cubic clip fold wrap decimator`          |
| Enveloppes | `env_perc env_linen env_adsr env_asr env_cutoff env_sine`         |
| Triggers   | `trig_kr t_delay pitch_shift freq_shift vibrato_sig`              |
| Buffers    | `play_buf buf_rd`                                                 |
| Demand     | `demand_seq demand_white t_rand`                                  |

## Le `|>` d'Elixir

Dans `@synth`, `x |> f(a, b)` insère `x` comme premier argument : c'est
le pipe d'Elixir. Les fonctions du DSL sont écrites pour ça
(`saw(:freq) |> rlpf(800, 0.3) |> tanh_drive(2)`), et **n'importe quelle
fonction** dont le premier argument est un signal se pipe aussi, y
compris les tiennes et `ugen` :

```julia
mon_drive(s, k) = s |> tanh_drive(k) |> soft_clip
@synth :x (freq=220) saw(:freq) |> mon_drive(3) |> ugen(:RLPF, 800, 0.3)
```

- une fonction nue se pipe : `saw(:freq) |> soft_clip` ;
- `_` choisit la place et appelle la fonction telle quelle :
  `saw(:freq) |> ugen(:Pan2, _, 0.2, 1)` ;
- les mots-clés restent : `|> env_perc(0.01, 0.4; level = 0.8)` ;
- un nombre ou un contrôle pipé devient un signal : `4.0 |> clip2(1.0)`,
  `:freq |> round_q(q)`.

Et la **capture** d'Elixir : `&rlpf(&1, 800, 0.3)` est la fonction
`x -> rlpf(x, 800, 0.3)`, `&(&1 + &2)` en prend deux. Pratique pour nommer
une étape et la réutiliser :

```julia
@synth :x (freq=220) begin
    drive = &tanh_drive(&1, 2)
    saw(:freq) |> drive |> low_pass(1200)
end
```

Toutes les fonctions du DSL prennent le signal en premier argument :
hors de `@synth` (au REPL), `|>` est celui de Julia et on écrit
`rlpf(x, 800, 0.3)`.

## Arithmétique sur Sig

`+ - * /` sont surchargés pour `Sig × Sig`, `Sig × Real`, `Sig × Symbol`,
`Symbol × Real` (les symboles représentent les arguments du SynthDef).
`:freq * 2` dans une expression devient `(freq * 2)` en SC.

## Recettes

```julia
# Kick
@synth :kick (sustain=0.4)
    sin_osc(line(120, 40, 0.05)) |> env_perc(0.001, :sustain)

# Cloche FM
@synth :fmbell (freq=440, sustain=1.5)
    sin_osc(:freq + sin_osc(:freq * 1.41) * line(800, 50, 0.5))
    |> env_perc(0, :sustain)

# Basse acid avec enveloppe sur le cutoff
@synth :acid (freq=60, sustain=0.3)
    saw(:freq) |> rlpf(line(3000, 500, :sustain), 0.18)
    |> tanh_drive(2)

# Pincé Karplus-Strong
@synth :pluck (freq=220, sustain=1.5)
    white() |> env_perc(0, 0.005)
    |> comb_l(1 / :freq, :sustain, 0.05)
    |> low_pass(:freq * 4)

# Nappe désaccordée
@synth :pad (freq=220, sustain=4) (auto_env=false,)
    (saw(:freq) + saw(:freq * 1.007) + saw(:freq * 0.993))
    |> low_pass(2000) |> free_verb(0.5, 0.9, 0.5)

# Wobble avec chorus
@synth :wob (freq=80) (auto_env=false,)
    saw(:freq) |> rlpf(lfo(4; low=400, high=2000), 0.3)
    |> chorus(0.4, 0.003, 0.6)

# Flange métallique
@synth :metal (freq=220, sustain=0.5)
    pulse(:freq, 0.4) |> flanger(0.15, 0.008, 0.6)
    |> env_perc(0.001, :sustain)

# Phaser années 70
@synth :sweepy (freq=220, sustain=2)
    saw(:freq) |> phaser(0.3, 800) |> env_linen(0.01, :sustain, 0.2)
```

## Sources chaotiques / non linéaires

Des UGens chaotiques audio (sc3-plugins), câblés dans le DSL comme des
oscillateurs. Ils vont partout où `saw()` ou `white()` irait. L'argument
`freq` est la **vitesse d'itération** du système — pas une hauteur à
proprement parler, mais il tombe dans la zone audible réglé près des
fréquences de notes.

| UGen           | Caractère                                          |
| -------------- | -------------------------------------------------- |
| `lorenz`       | attracteur continu 3D — doux, bon pour les drones  |
| `henon`        | carte 2D — sec, glitché, percussif                 |
| `logistic`     | carte 1D — `paramA` ∈ [3.57, 4] choisit le chaos   |
| `standard_map` | conserve les aires — bourdonnant, `k` = intensité  |
| `latoo`        | Latoocarfian — très « buzz bruité », bon en nappe  |
| `lincong`      | congruentiel linéaire — peut être très accordé     |
| `quad`         | carte quadratique                                  |
| `fbsine`       | sinus à feedback — cloche FM avec `im`/`fb` élevés |
| `gbman`        | carte Gingerbreadman — 2D conservative             |
| `cusp`         | catastrophe fronce                                 |

### Pourquoi une note ne s'entend pas sur un synth chaotique

Un `@synth` bâti sur `henon`, `latoo` ou `logistic` reçoit bien la note :
`freq` est déclaré, donc `n("0 12")` la convertit en fréquence et
l'envoie. Mais `freq` est la **vitesse d'itération** de la carte, pas
celle d'un oscillateur périodique. Réglée en plein chaos, la carte ne se
répète jamais : le spectre est large, il n'y a pas de fondamentale, et la
note change la texture plutôt que la hauteur.

Pour entendre une hauteur, il faut ramener la carte dans une **fenêtre
périodique**. Sur Hénon, c'est le paramètre `a` qui décide (avec
`b = 0.3`) :

| `a`  | comportement | hauteur perçue |
|------|--------------|----------------|
| 1.0  | période 4    | `freq` (la note nominale) |
| 1.05 | période 8    | une octave plus bas |
| 1.25 | période 7    | ≈ une quinte plus bas |
| 1.1 · 1.2 · 1.4 | chaos | aucune |

`chaoglitch` itère à `:freq * 4`, donc avec `a = 1.0` (période 4) la
forme d'onde se répète exactement `freq` fois par seconde : la note tombe
juste.

```julia
@d1 :chaoglitch |> n("0 3 7 12")                 # texture, pas de hauteur
@d1 :chaoglitch |> n("0 3 7 12") |> set(:a, 1.0) # la mélodie s'entend
@d1 :chaoglitch |> n("0 3 7") |> set(:a, "<1.0 1.05 1.4>")  # va et vient
```

Deux réglages aident encore. Un filtre fixe masque le mouvement :
remplacer `rlpf(2200, 0.4)` par `rlpf(:freq * 6, 0.4)` dans la recette
fait suivre le spectre à la note. Et un `sustain` plus long laisse le
temps d'entendre la périodicité.

La même idée vaut pour les autres cartes : `logistic` est périodique
sous `paramA ≈ 3.57`, `lincong` est réputé le plus facile à accorder,
`latoo` reste bruité quoi qu'on fasse.

Chacun enveloppe la variante **-L** (interpolation linéaire). Pour les
versions brutes ou cubiques, l'échappatoire `ugen()` :

```julia
@synth :rawlo  ugen(:LorenzN, :freq, 10, 28, 8/3, 0.05) |> rlpf(800, 0.3)
@synth :smoolo ugen(:LorenzC, :freq, 10, 28, 8/3, 0.05) |> rlpf(800, 0.3)
```

### Recettes — sources chaotiques

Six exemples prêts à l'emploi dans `plugins/user-synths/` — `:lib`,
filtre `chaos` :

```julia
# Drone Lorenz — itération lente = texture grondante
@synth :chaodrone (freq=80, sustain=4, cutoff=600) begin
  lorenz(:freq * 6, 10, 28, 8/3, 0.05) |>
  rlpf(:cutoff, 0.3) |> tanh_drive(1.2)
end

# Glitch Hénon — accordé mais harmoniquement bruité
@synth :chaoglitch (freq=440, sustain=0.18, a=1.4, b=0.3) begin
  henon(:freq * 4, :a, :b) |>
  rlpf(2200, 0.4) |> env_perc(0.001, :sustain)
end

# Nappe Latoocarfian — LP lourd + réverb domptent le buzz
@synth :chaopad (freq=220, sustain=4) (auto_env=false,) begin
  latoo(:freq * 16, 1.0, 3.0, 0.5, 0.5, 0.5, 0.5) |>
  low_pass(lfo(0.18; low=600, high=2200)) |>
  free_verb(0.5, 0.92, 0.6) |> amp(0.35)
end

# Basse logistique au seuil du chaos
@synth :chaobass (freq=55, sustain=0.45, drive=1.4) begin
  logistic(:freq * 8, 3.9, 0.5) |>
  low_pass(:freq * 8) |> tanh_drive(:drive) |>
  env_perc(0.005, :sustain)
end

# Sinus à feedback façon FM — monte im/fb pour plus de cloche
@synth :chaofm (freq=220, sustain=1.2, im=1.0, fb=0.1) begin
  fbsine(:freq * 100, :im, :fb, 1.1, 0.5, 0.1, 0.1) |>
  rlpf(:freq * 8, 0.3) |> env_perc(0.005, :sustain)
end

# Pincé LinCong — un Karplus-Strong abîmé
@synth :chaopluck (freq=220, sustain=1.0, damp=0.5) begin
  lincong(:freq * 64, 1.1, 0.13, 1.0, 0.0) |>
  comb_l(1 / :freq, :sustain, 0.05) |>
  low_pass(:freq * 6) |> env_perc(0.001, :sustain)
end
```

### Piloter les paramètres chaotiques depuis un pattern

Chaque UGen chaotique expose ses paramètres comme contrôles SC : on les
balaie en live comme n'importe quel paramètre :

```julia
@d1 :chaobass |> n("0 3 5 7") |> set(:drive, sine() |> range_pat(1.0, 2.5))
@d2 :chaoglitch |> set(:a, perlin() |> range_pat(1.0, 1.5))
```

Voir `14-chaos-reservoir.md` pour la vue d'ensemble (chaos au taux de
contrôle et synthèse pilotée par réservoir).

## La librairie intégrée

`:lib` (ou `Espace L`) liste tous les synths prêts à jouer, dont un kit
de batterie façon 909 : `@d1 "k909 ~ s909 ~"`.

- **perc** : `kick hihat snare clap glitchhat kickbrut`
- **tr909** : `k909 s909 hh909 oh909 cp909 rim909 ride909 tom909`
- **bass** : `subdrop acid303 rezzbass growlbass chompy`
- **lead** : `fmbell bellsynth plucky`
- **pad** : `softpad airpad glasspad ghostpad`
- **darksynth** : `kickbrut darklead arpdriver darkpad`
- **witch** : `dustbass screwlead ghostpad`
- **lofi** : `lofibass lofikey mellowfm chordstab vinylcrackle`
- **fx** : `lazerzap darkriser`

`Espace` écoute un synth dans la liste ; `Entrée` l'ouvre dans une pane
synth (une copie éditable de la recette — modifie et `T` pour entendre).
`:synth <nom>` fait pareil directement, et `gs` depuis un pattern.

## Sculpter un son

Dans le workspace DESIGN, le **STUDIO** (en haut à droite) suit le texte :
dès que le `@synth` change et que tu n'es plus en insertion, il reconstruit
le graphe du son, son onde et ses knobs, et la DOC (en bas à droite) reçoit
l'explication. `Ctrl-w l` amène le focus dans le studio, `:sculpt` aussi.

Dans l'autre sens, ce que tu fais dans le studio revient dans le texte :

- **un nombre** tiré (`h`/`l`, `=`) est remplacé **sur place** quand il se
  retrouve tel quel, et une seule fois, dans le texte — `freq=220` devient
  `freq=226.443`, rien d'autre ne bouge ;
- **un changement de structure** (`o` change l'UGen, `n` insère un filtre,
  `d` supprime un nœud, `x` duplique, `m` greffe un LFO) ou un nombre
  introuvable (une valeur calculée) réécrit le bloc `@synth` en **forme
  canonique**, une ligne par nœud. Le log le dit, `u` dans le texte annule.

L'onglet **graphe** de la DOC (`→` deux fois, ou `G` depuis le studio)
dessine le son tel qu'il est câblé : la chaîne principale de la matière
vers la sortie, en boîtes reliées par des flèches, une couleur par rôle,
et sous chaque boîte ce qui la module avec le nom du slot sur l'arête. Le
nœud focalisé dans le studio est en trait épais ; `h`/`l` passent d'un
nœud à l'autre et le studio suit, `Enter` ramène le focus sur son knob,
`d` retire le nœud, `[` `]` défilent un grand graphe, ✂ marque ce qui ne
s'entend pas.

`:w` sauve, `U` l'utilise dans un pattern, `P` mesure l'impact de chaque
nœud. Hors de DESIGN, `:sculpt` et `M` sur un candidat de l'explorateur
ouvrent un studio seul, avec son explication à côté des knobs. Voir `?`
dans le studio.

## Inspecter sans jouer

```julia
synth_source(:foo, saw(:freq); params=(freq=440,))
# → renvoie la source SC du SynthDef sans l'envoyer
```

## Comprendre et élaguer un synth

`:explain` (ou `:explain nom`) décrit le son du buffer : la chaîne de
la sortie vers la matière, le rôle de chaque nœud, pourquoi ça sonne
comme ça, et une section ÉLAGAGE qui pointe ce qui ne s'entend pas
(nœud hors de la chaîne, saturation redondante, source à 0 Hz…).

`:prune` dans la pane synth retire ces nœuds, puis — si `sclang`
répond — ceux dont l'impact mesuré est sous 0,02 (`:prune 0.05` pour
élargir) : le son est rendu hors-ligne sans chaque nœud et comparé au
complet. Le bloc `@synth` est réécrit sous sa forme canonique
(`n1 = …`), le reste du fichier reste intact ; `T` pour écouter, `:w`
pour sauver. Le studio sculpt (`:sculpt`) montre la même chose nœud
par nœud, avec `P` pour mesurer et `d` pour retirer à la main.

