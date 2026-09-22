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

## Drones — sans enveloppe automatique

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

`:sculpt` (ou `M` sur un candidat de l'explorateur) ouvre le **studio
sculpt** : l'onde du son en haut, ses paramètres (« knobs ») groupés par
fonction, et l'explication de ce qui fait le son. `h`/`l` tirent un knob,
`=` saisit une valeur, `o` change l'UGen, `n` insère un filtre, `d`
supprime un nœud, `x` duplique, `m` greffe un LFO. `:w` sauve, `U`
l'utilise dans un pattern. Voir `?` dans le studio.

## Inspecter sans jouer

```julia
synth_source(:foo, saw(:freq); params=(freq=440,))
# → renvoie la source SC du SynthDef sans l'envoyer
```
