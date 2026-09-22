# Recettes

Des recettes à copier-coller pour les gestes courants du live-coding.
Dans la pane patterns, `e` évalue la ligne, `E` évalue tout.

## Construire un beat de zéro

```julia
cps!(0.5)
@d1 "bd ~ bd ~"               # kick sur 1 et 3
@d2 "~ cp ~ cp"               # clap sur 2 et 4
@d3 "hh*8" |> gain(0.4)       # charley en croches
```

Ajoute une basse :

```julia
@d4 :subdrop |> n("0 ~ -2 ~ 0 ~ 5 ~") |> gain(0.6)
```

Ou plus vite avec Espace-leader — `Espace d` insère `@d$1 "$2"` avec
navigation entre les trous : tape le slot, Tab, tape le corps, Esc.

## Varier en une touche

Les combinateurs façon Tidal transforment un pattern sur place :

```julia
@d1 "bd hh sn hh" |> jux(rev)              # stéréo : G original, D inversé
@d1 "bd hh sn hh" |> sometimes(fast(2))    # un cycle sur deux en double vitesse
@d1 "hh*8" |> degradeBy(0.3)               # laisse tomber 30 % des coups
@d1 "bd hh sn hh" |> iter(4)               # tourne d'1/4 par cycle
@d1 "bd hh sn hh" |> palindrome            # à l'endroit puis à l'envers
@d1 "bd hh sn hh" |> chunk(4, fast(2))     # un morceau par cycle en rapide
@d1 "bd hh sn hh" |> off(1//8, fast(2))    # superpose une copie décalée
```

Ou directement en mini-notation :

```julia
@d1 "bd? hh? sn hh?"           # ?  = laisse tomber à 50 %
@d1 "bd?0.3 hh sn hh"           # ?N = probabilité personnalisée
@d1 "bd _ _ sn"                 # _  = prolonge le pas précédent
@d1 "bd(3,8,2) cp(1,8,4)"       # 3e arg = rotation euclidienne
```

## Starters de genre

```
:starter house       :starter dnb        :starter jersey
:starter trap        :starter lofi       :starter dubstep
:starter idm         :starter jungle     :starter amapiano
:starter hardcore    :starter witchhouse :starter ambient
```

…et `:snip` en propose d'autres dans la catégorie `genre` (Tab pour y
aller) : jersey, footwork, garage, breakcore, drill, dembow, boombap,
lofi_hiphop, phonk, witch_house, bossanova.

## Pompage sidechain

Sans vrai sidechain audio (qui demande de la plomberie SC), le son
reconnaissable du pompage est juste une courbe de gain calée sur le
cycle :

```julia
@d1 :super808 |> n("0 ~ ~ 0") |> gain(1.2)    # kick sur 1 et 3
@d2 :supersaw |> n("-7 -5 -3 -7") |> pump(8, 0.7) |> gain(0.6)
#                                       └── 8 creux par cycle, profondeur 0.7
```

La nappe s'efface à chaque kick — ce que la plupart des gens veulent
dire par « sidechain ».

## Balayages de filtre et mouvement de LFO

Les valeurs `"<...>"` avancent d'un pas par cycle :

```julia
@d1 :acid303 |> n("0 3 5 7") |> set(:cutoff, "<400 800 1600 3200>")
```

`<>` tourne à chaque cycle ; avec un multiplicateur pour un balayage
lent :

```julia
@d1 :supersaw |> lpf("<400 800 1200 2000 1200 800>" |> slow(2))
```

## Le chaos comme modulation

Les générateurs chaotiques côté pattern vivent dans le plugin `chaos`.
Chacun renvoie un `Pattern{Float64}` à mettre dans `set(...)` comme
`sine()` ou `perlin()`. Référence complète dans
[14-chaos-reservoir](14-chaos-reservoir.md).

> **Vite fait :** `:starter chaos` charge une démo prête à évaluer.

```julia
# Attracteur de Lorenz sur le cutoff
@d1 :acid303 |> n("0 3 5 7") |>
   set(:cutoff, Chaos.lorenz(axis=:x) |> range_pat(400, 4000))

# Carte de Hénon sur la vitesse de LECTURE des samples (hauteur + durée)
@d2 "bd hh sn hh" |> set(:speed, Chaos.henon() |> range_pat(0.8, 1.4))

# …et sur la vitesse du RYTHME : un facteur par cycle pour `fast`
@d3 "bd hh sn hh" |> fast(Chaos.henon() |> segment(1) |> range_pat(1, 3) |> quantise)

# Logistique au bord du chaos sur le pan
@d3 :supersaw |> n("0 3 7 10") |>
   set(:pan, Chaos.logistic(r=3.95) |> range_pat(-0.8, 0.8))
```

`segment(N)` discrétise un signal chaotique continu en N pas par cycle
pour une modulation quantifiée plutôt que lisse :

```julia
@d1 :pad |> set(:cutoff,
   Chaos.rossler() |> segment(8) |> range_pat(500, 3000))
```

## Patterns pilotés par réservoir

Des réservoirs de neurones à impulsions + automates cellulaires vivent
dans le plugin `reservoir`. Trois routes de l'état du réservoir au son :

> **Vite fait :** `:starter reservoir-spike` (route I),
> `:starter reservoir-spectral` (route II), ou
> `:starter reservoir-mix` (les trois).

```julia
# Route I — chaque impulsion tire une bouffée de sinus à une fréquence
# assignée par la disposition. AdEx en mode bursting, gamme pentatonique.
r = Reservoir.adex(N=48, params=Reservoir.ADEX_BURSTING, seed=42)
@d1 Reservoir.spike_burst(r; drive=600.0, layout=:scale,
                          layout_args=(scale=:minor_pentatonic, root=220))

# Route II — resynthèse additive (16 partiels par trame).
# RECA règle 110 (Turing-complète, bord du chaos) sur une série harmonique.
r2 = Reservoir.reca(N=16, rule=110, init=:single)
@d2 Reservoir.spectral_cloud(r2; frames_per_cycle=8,
                             layout=:harmonic, layout_args=(fund=110,))

# Route III — le réservoir comme modulateur scalaire d'un paramètre.
r3 = Reservoir.adex(N=16, seed=1)
mod = Reservoir.modulator(r3, neuron=5, drive=500.0) |> range_pat(400, 4000)
@d3 p"bd*4" |> set(:cutoff, mod)
```

Règles et paramètres donnent des textures très différentes — la règle 30
est entièrement chaotique, la 90 fait des motifs de Sierpinski, la 184
ressemble à du trafic routier, `ADEX_BURSTING` tire des bouffées,
`ADEX_FAST` des impulsions toniques. `slow(N)` / `fast(N)` recalent sur
des cycles musicaux.

## Effets de modulation (DSL)

```julia
:synth wob
@synth :wob (freq=80) (auto_env=false,)
    saw(:freq) |> rlpf(lfo(4; low=300, high=2400), 0.3)
    |> chorus(0.4, 0.003, 0.5)

# Puis dans les patterns :
@d1 :wob |> n("-12 -7 -12 -10") |> gain(0.7)
```

Trois effets à delay modulé exposés dans le DSL :

```julia
saw(:freq) |> chorus(rate=0.5, depth=0.002, mix=0.5)
saw(:freq) |> flanger(rate=0.2, depth=0.005, feedback=0.3)
saw(:freq) |> phaser(rate=0.3, depth=800)
```

## Kit 909 (librairie intégrée)

La catégorie `tr909` de la librairie donne des voix 909 éditables :

```julia
@d1 "k909 ~ s909 ~"                          # kick + caisse claire sur 2/4
@d2 "hh909*8" |> gain(0.4)                   # charleys fermés
@d3 "~ ~ ~ ~ ~ ~ oh909 ~" |> gain(0.5)       # charley ouvert
@d4 "~ ~ cp909 ~" |> room(0.3)               # clap avec réverb
@d5 "tom909(3,8)" |> n("<-5 0 5 12>")       # toms qui changent de hauteur
```

Ouvre-les (`:lib`, cherche `k909`, Entrée — ou `:synth k909`) pour
éditer la recette DSL.

## Textures polyrythmiques

```julia
@d1 "bd*3"          # 3 coups par mesure
@d2 "sn*4" |> gain(0.5)
@d3 "hh*5" |> gain(0.3)
```

Ou euclidien pour la pulsation roulante :

```julia
@d1 "bd(3,8)"
@d2 "sn(5,16)" |> gain(0.6)
@d3 "hh(7,16)" |> gain(0.4)
```

Avec une rotation pour décaler chaque couche :

```julia
@d1 "bd(3,8,0)"
@d2 "cp(1,8,4)"     # clap sur le 3
@d3 "hh(11,16,2)"
```

## Chaîne d'effets dub

```julia
@d1 "bd ~ sn ~" |> delay(0.5) |> delaytime(0.375) |>
    delayfeedback(0.6) |> room(0.7)
```

`Espace D` insère toute la chaîne de delay d'un coup.

## Taper un rythme avec les mains

```
:tap                                    # démarre l'enregistrement
Espace Espace Espace ...                # tape le rythme deux fois (détection de boucle)
Entrée                                  # valide en cps!() + @dN "..."
                                        # et évalue tout de suite
```

La status line compte les coups en direct. La sortie est ce que tu as
joué : période détectée, cps ajusté, écrit + évalué en une touche.

Pour un rythme unique sans détection : `:tap-strict`.
Pour le tempo seul : `:bpm` (4 taps = 1 mesure).

## Jouer une mélodie au clavier

```
:piano-rec fmbell
```

Les lettres jouent des notes (z/x/c/v/b/n/m = naturelles, s/d/g/h/j =
dièses), `[` `]` changent d'octave, Entrée valide les notes enregistrées
en `@dN :fmbell |> n("…")`.

## Mixer en live avec `:mixer`

Dans `:mixer` :

- `j` / `k` — naviguer entre les slots
- `+` / `-` — gain ±0.1 (écrit dans le buffer + ré-évalue le slot)
- `*` / `/` — gain ±0.5
- `m`       — mute / démute
- `s`       — solo (mute tout le reste)
- `u`       — tout démuter
- `!`       — panic
- `q`       — fermer

La barre d'activité montre les derniers tirs (décroît sur 0,6 s — pas un
vrai RMS mais assez pour voir ce qui joue).

## Sauver / charger une session

```
:save idee          → sessions/idee.txt
:load idee          → recharge le buffer (E pour évaluer)
:sessions           → liste les sessions
:load <Tab>         → complète les noms de sessions
```

## Ajouter un sample

```
:import ~/Downloads/mykick.wav as fatkick
@d1 "fatkick ~ fatkick ~"
```

Ré-importer sous le même nom ajoute une variante (`fatkick:1`,
`fatkick:2` deviennent disponibles pour `n()`). Voir
[09-samples](09-samples.md).

## Exporter un son en WAV

```
:export 6           → enregistre le synth focalisé pendant 6 s,
                      écrit ./recordings/<nom>_<horodatage>.wav
```

Ou une prise plus longue du master :

```
:rec start mytrack
... joue ...
:rec stop           → ./recordings/mytrack.wav
```

## Piloter Ressac depuis un clavier MIDI

Colle 6 lignes de SC dans ta session SuperCollider et chaque note-on
devient un déclencheur Ressac :

```supercollider
MIDIClient.init; MIDIIn.connectAll;
~ressacOSC = NetAddr.new("127.0.0.1", 57121);
MIDIFunc.noteOn({ |vel, num, chan|
    ~ressacOSC.sendMsg("/ressac/trigger", "supersaw",
        "n", (num - 60).asInteger,
        "gain", (vel / 127).asFloat);
});
```

Le détail dans [13-external-midi](13-external-midi.md).
