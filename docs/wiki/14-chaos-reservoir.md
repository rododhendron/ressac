# Chaos et réservoir

Ressac embarque deux plugins qui font de la matière musicale à partir de
systèmes dynamiques : **chaos** (générateurs chaotiques comme patterns) et
**reservoir** (réservoirs de neurones à impulsions / automates
cellulaires qui pilotent des événements de synthèse). Les deux suivent
l'architecture de plugin standard : les mêmes patterns peuvent être
étendus par des plugins communautaires.

> **Tu veux juste entendre ?** Tape dans la TUI :
> `:starter chaos` · `:starter reservoir-spike` ·
> `:starter reservoir-spectral` · `:starter reservoir-mix`.
> Chacun charge une démo de 4 à 8 lignes prête à évaluer avec `E`.

Il existe aussi une surface chaotique **au taux audio** dans le DSL de
synthèse (voir [03-synth-dsl](03-synth-dsl.md), § Sources chaotiques) —
celle-là, c'est du chaos *dans* les SynthDefs, calculé par SuperCollider.
Cette page concerne les générateurs **côté Julia**, qui émettent des
patterns que le scheduler envoie à SC par OSC.

```
                  taux de contrôle (Julia)     taux audio (SC)
                  ─────────────────────        ────────────────
plugin chaos      sources Pattern{Float64}     ─
                  modulent les paramètres
DSL de synthèse   ─                            lorenz(), henon(), …
                  dans @synth comme white() / saw()
plugin reservoir  sources Pattern{ControlMap}  (rien encore — les routes
                  tirent des événements SC     II + III synthétisent via
                  depuis les impulsions        des SynthDefs ordinaires)
```

## Plugin chaos

Cinq systèmes chaotiques intégrés, chacun renvoyant un `Pattern{Float64}` :

| Nom           | Type                      | Sortie                   |
| ------------- | ------------------------- | ------------------------ |
| `lorenz`      | attracteur continu 3D     | axe `:x`, `:y` ou `:z`   |
| `henon`       | carte discrète 2D         | `:x` ou `:y`             |
| `logistic`    | carte discrète 1D         | scalaire                 |
| `rossler`     | attracteur continu 3D     | `:x`, `:y` ou `:z`       |
| `standard`    | carte standard de Chirikov | `:p` (moment) ou `:θ`   |

```julia
# Usage direct
p = Chaos.lorenz(σ=10, ρ=28, β=8/3, axis=:x)
p(0//1, 1//1)   # => [Event{Float64}(...)]

# Balayer un cutoff
@d1 :acid303 |> set(:cutoff, Chaos.lorenz() |> range_pat(400, 4000))

# Discrétiser en N pas par cycle
@d2 :pad |> set(:room, Chaos.henon() |> segment(8) |> range_pat(0.1, 0.7))
```

### Discrétiser / mettre à l'échelle

Un pattern chaotique continu émet un événement par requête couvrant tout
l'arc. À combiner avec :

- `segment(N)` — N échantillons discrets par cycle
- `range_pat(lo, hi)` — remappe linéairement dans `[lo, hi]`
- `slow(N)` / `fast(N)` — recale le temps du chaos sur le temps musical

### Sémantique d'état

Chaque appel à `Chaos.lorenz(...)` construit un état neuf et indépendant.
Les requêtes ont un état (intégration en avant) : ré-interroger la même
fenêtre rend la même valeur ; interroger plus loin fait avancer le
système.

### Étendre — enregistrer un nouveau système

Un plugin (ou du code live) peut ajouter des générateurs :

```julia
function mychaos(; r=3.9, init=0.5)
    state = Ref(init)
    Ressac.Pattern{Float64}((s, e) -> begin
        state[] = r * state[] * (1 - state[])
        [Ressac.Event{Float64}(s, e, state[])]
    end)
end

Chaos.register_chaos!(:mychaos, mychaos)
@test :mychaos in Chaos.list_chaos()
```

## Plugin reservoir

Deux sortes de réservoirs et trois routes, tous composables.

### Sortes de réservoirs

**AdEx** — neurones à impulsions « adaptive exponential integrate-and-
fire » (Brette & Gerstner 2005). Des motifs de décharge riches selon les
paramètres :

```julia
r = Reservoir.adex(
    N=64,                         # nombre de neurones
    params=ADEX_BURSTING,         # aussi ADEX_REGULAR (défaut), ADEX_FAST
    dt=1.0,                       # ms par pas de simulation
    steps_per_cycle=1000,         # → ~1 s de temps neuronal par cycle Ressac
    p_connect=0.1,                # connectivité récurrente clairsemée
    W_gain=180.0,                 # échelle des poids synaptiques (pA par impulsion)
    V_init=:scattered,            # V aléatoire uniforme au départ (moins synchrone)
    σ_noise=400.0,                # volatilité du bruit OU de base (pA)
    τ_noise=20.0,                 # temps de corrélation OU (ms)
    inhibitory_fraction=0.2,      # principe de Dale : 20 % d'unités inhibitrices
    seed=42,
)
```

**Bruit OU de base** (`σ_noise`, `τ_noise`) injecte un bruit coloré comme
courant supplémentaire à chaque pas. Avec `σ_noise = 0` les neurones
restent au repos ; avec `σ_noise ≈ 400-600` V flotte près du seuil — toute
excitation externe synchronise la population. Imite l'état « à haute
conductance » in vivo, où les neurones corticaux sont toujours bruyants et
deviennent rythmiques sous excitation thalamique.

**Principe de Dale** (`inhibitory_fraction`) marque une fraction des
neurones comme inhibiteurs — leurs poids sortants sont forcés négatifs.
`0.0` (défaut) garde des poids de signe aléatoire ; `0.2` est la
proportion corticale typique (80 % E, 20 % I).

### Sources d'excitation flexibles

Le mot-clé `drive` de chaque route accepte :

| Forme | Exemple | Effet |
| ----- | ------- | ----- |
| `Real` | `drive=500.0` | courant constant en pA sur tous les neurones |
| `Vector` | `drive=[100,200,...]` | statique par neurone (longueur N) |
| `Function` | `drive=(c,s) -> 400+200*sin(2π*s/500)` | appelée à chaque pas, renvoie Real ou Vector |
| `Pattern{Symbol}` | `drive=p"bd ~ sn ~"` | chaque événement excite le neurone `hash(valeur) % N + 1` pendant 10 pas |
| `Pattern{Float64}` | `drive=sine() \|> range_pat(0,600)` | signal continu échantillonné par cycle, diffusé |

**RECA** — Reservoir Computing with Elementary Cellular Automata (Yilmaz
2014). Un tableau de bits 1D qui évolue sous une règle de Wolfram :

```julia
r = Reservoir.reca(
    N=128,
    rule=110,                     # 0..255 — voir les notes plus bas
    init=:single,                 # :rand ou :zero
    boundary=:wrap,               # :zero pour non torique
    steps_per_cycle=16,
    seed=42,
)
```

Règles intéressantes :
- `30` — entièrement chaotique, le réservoir RC canonique
- `90` — triangle de Sierpinski depuis une cellule
- `110` — Turing-complète, bord du chaos
- `184` — trafic routier, très ordonné
- `54` — comportement complexe (classe IV)

### Route I — impulsion → bouffée de sinus

Chaque impulsion du neurone `i` tire un sinus percussif à la fréquence
que la disposition lui assigne. Dispositions : `:logfreq`, `:scale`,
`:harmonic`, `:cluster`.

```julia
r = Reservoir.adex(N=64, params=ADEX_BURSTING, seed=42)
@d1 Reservoir.spike_burst(r;
    drive=600.0,                    # courant d'entrée constant (pA)
    layout=:scale,
    layout_args=(scale=:minor_pentatonic, root=220),
    burst_dur=1//16,                # durée de l'événement (cycles)
    gain=0.5,
)
```

Gammes disponibles pour `layout=:scale` :
`minor_pentatonic major_pentatonic dorian phrygian lydian
mixolydian natural_minor harmonic_minor whole_tone chromatic`

### Route II — nuage spectral (resynthèse additive)

Tire `frames_per_cycle` événements par cycle, chacun portant 16
amplitudes de partiels lues dans l'état du réservoir. Un fondu enchaîné
lisse les transitions.

```julia
r = Reservoir.reca(N=16, rule=110, init=:single)
@d2 Reservoir.spectral_cloud(r;
    bins=16,                        # correspond au SynthDef specloud16
    frames_per_cycle=8,
    layout=:harmonic,
    layout_args=(fund=110,),
    overlap=2.0,                    # 1.0 = bout à bout, 2.0 = 50 % de fondu
    gain=0.3,
)
```

Pour AdEx, l'amplitude vient de `:V` (potentiel de membrane), écrêtée et
normalisée dans `[0, 1]`. Pour RECA, c'est l'état du bit (0 ou 1).
Personnalise avec `amplitude_kind` et `amplitude_scale`.

### Route III — modulateur scalaire

Lire l'état d'un neurone comme signal de contrôle continu — dans
n'importe quel `set(:param, …)`.

```julia
r = Reservoir.adex(N=16, seed=1)
mod = Reservoir.modulator(r,
    neuron=5,
    kind=:V,                        # ou :w, :spike, :density
    drive=500.0,
    scale=identity,                 # transformation Float64 → Float64
) |> range_pat(400, 4000)

@d3 p"bd*4" |> set(:cutoff, mod)
```

`kind` par type :
- **AdEx** : `:V` potentiel de membrane · `:w` adaptation · `:spike` bool du dernier pas · `:density` fraction active
- **RECA** : `:bit` état de la cellule · `:spike` bool du dernier pas · `:density` fraction active

### Le contrat d'interface

Une « sorte de réservoir » est toute valeur qui implémente :

```julia
step!(r, input::AbstractVector{Float64})        # avance d'un pas
spikes(r) -> AbstractVector{Bool}               # qui a tiré à ce pas
Base.length(r) -> Int                           # nombre d'unités
steps_per_cycle(r) -> Int                       # résolution cycle ↔ pas
read_state(r, kind::Symbol, neuron::Int) -> Float64
default_modulator_kind(r) -> Symbol             # ce que `:auto` résout
```

Implémente-les et appelle `Reservoir.register_reservoir!(:mykind, ctor)` :
ton réservoir hérite des routes I/II/III sans rien d'autre.

### Dispositions (mapping de fréquences)

Les dispositions décident quelle note chaque neurone / cellule reçoit
dans les routes I et II. Intégrées :

| Nom         | Comportement                                 | Mots-clés                   |
| ----------- | -------------------------------------------- | --------------------------- |
| `:logfreq`  | log-uniforme entre `lo` et `hi`              | —                           |
| `:scale`    | quantifiée sur une gamme à travers les octaves | `scale=`, `root=`         |
| `:harmonic` | i · fund (1f, 2f, 3f, …)                     | `fund=`                     |
| `:cluster`  | grappe linéaire dense autour de `center`     | `center=`, `spread=`        |

Ajoute la tienne :

```julia
Reservoir.register_layout!(:my_layout, (N, lo, hi; kwargs...) -> begin
    # … renvoie un Vector{Float64} de longueur N
end)
```

## Combiner les deux mondes

Un UGen chaotique audio comme voix + un réservoir au taux de contrôle
comme modulateur :

```julia
# Une basse chaotique sur mesure …
@synth :chaobass (freq=55, sustain=0.45, drive=1.4) begin
  logistic(:freq * 8, 3.9, 0.5) |> low_pass(:freq * 8) |>
  tanh_drive(:drive) |> env_perc(0.005, :sustain)
end

# … dont le paramètre `drive` est modulé par un Lorenz lent, les notes
# déclenchées par des impulsions AdEx sur une pentatonique mineure.
r = Reservoir.adex(N=16, params=ADEX_BURSTING, seed=42)
@d1 Reservoir.spike_burst(r; drive=600.0, layout=:scale,
                          layout_args=(scale=:minor_pentatonic, root=110),
                          synth=:chaobass) |>
   set(:drive, Chaos.lorenz() |> range_pat(0.8, 2.4))
```

## Référence : où vivent les choses

```
plugins/chaos/                    générateurs chaotiques côté Julia
├── chaos.jl                      module Chaos + 5 systèmes
└── plugin.toml

plugins/reservoir/                réservoir + 3 routes
├── reservoir.jl                  module Reservoir + contrat d'interface
├── adex.jl                       neurones AdEx + AdExReservoir
├── reca.jl                       réservoir d'automate cellulaire élémentaire
├── layouts.jl                    dispositions de fréquences (logfreq/scale/...)
├── route_spike.jl                route I — impulsion → bouffée
├── route_modulator.jl            route III — lecture scalaire
├── route_spectral.jl             route II — resynthèse additive
├── sineburst.scd                 voix de la route I
├── specloud16.scd                voix de la route II (16 partiels additifs)
└── plugin.toml

src/synth_dsl.jl                  UGens chaotiques audio (dans le DSL)
└── lorenz/henon/.../cusp         wrappers sc3-plugins
```
