# Venir de TidalCycles

Si tu as pratiqué Tidal en Haskell, le modèle mental et presque tout le
vocabulaire se transposent. Les grandes différences :

| Tidal (Haskell)            | Ressac (Julia)                 |
|----------------------------|--------------------------------|
| `cps 0.5`                  | `cps!(0.5)`                    |
| `d1 $ s "bd"`              | `@d1 "bd"`  ou `@d1 :bd`       |
| `d1 silence`               | `@d1`        (sans corps = vide) |
| `hush`                     | `:hush` ou `,`                 |
| pipe `#`                   | pipe `\|>`                     |
| `s "bd" # gain 0.7`        | `"bd" \|> gain(0.7)`           |
| `n "0 3 5"`                | `n("0 3 5")`                   |
| `every 4 rev`              | `every(4, rev)`                |
| `jux rev`                  | `jux(rev)`                     |
| `degradeBy 0.3`            | `degradeBy(0.3)`               |
| `(|+|) pat1 pat2`          | pas encore — utilise `stack`   |

## Ce qui est pareil

- L'horloge : cycles par seconde, lookahead, ordonnancement polyphonique
  par événement.
- La grammaire de la mini-notation : `~`, `[…]`, `<…>`, `*`, `!`,
  `(k,n)`, `:`.
- La plupart des combinateurs, par nom : `fast`, `slow`, `rev`, `every`,
  `stack`, `cat`, `mask`, `gate`, `degrade`, `sometimes`, `often`,
  `rarely`, `palindrome`, `iter`, `chunk`, `jux`, `juxBy`, `off`.
- Les noms de samples via Dirt-Samples (bd, sn, hh, amen, …).
- SuperCollider / SuperDirt comme moteur audio (ton installation
  existante marche).

## Ce qui change

### Les valeurs de pattern

Dans Tidal, `s "bd hh sn"` est un `Pattern String`. Dans Ressac,
`"bd hh sn"` est un `Pattern{Symbol}` : l'atome devient un `Symbol`
Julia. Les indices de variante restent dans le symbole : `"bd:2"` →
`Symbol("bd:2")`.

Le raccourci `@d1 :bd` devient `pure(:bd)` automatiquement — pratique
pour un pattern à un seul nom.

### Le pipe est le `|>` de Julia

```julia
@d1 "bd hh sn hh" |> fast(2) |> gain(0.8) |> lpf(1500)
```

Règles de composition (comme le `#` de Tidal) :
- `gain` × · `lpf` min · `hpf` max · `speed` × · `pan` / `n` / `room` /
  `delay` / `shape` : le dernier gagne.

### `set` pour n'importe quel paramètre

Si un paramètre SuperDirt n'a pas de helper, `set(:clé, valeur)` le
passe :
```julia
@d1 "bd" |> set(:cut, 1) |> set(:vibrato, 4)
```

### Mini-notation probabiliste

```julia
"bd? hh? sn? hh?"      # chacun tombe à 50 %
"bd?0.3 hh sn hh"      # seul bd tombe, à 30 %
"bd _ _ sn"            # bd prolongé sur 3 pas
"bd(3,8,2)"            # euclidien 3-sur-8 tourné de 2 pas
```

Les tirages sont semés par `hash(début_de_l'événement)` : déterministes,
pas aléatoires à chaque rendu.

### La conception de sons vit dans la même TUI

Dans Tidal on écrit les SynthDefs en sclang (un autre éditeur). Dans
Ressac, le workspace DESIGN (`Ctrl-2`) tient la pane synth — `:synth wob`
l'ouvre. SuperCollider brut OU le DSL Julia embarqué
(`@synth :wob saw(:freq) |> rlpf(800, 0.3)`). `T` joue, `:w` sauve, `U`
pose le synth dans un pattern, `gs` remonte d'un pattern au synth.

### Couverture des fonctions Tidal

| Tidal | Ressac | Remarque |
|---|---|---|
| `fast` `slow` `hurry` `rev` `iter` `iter'` `palindrome` | `fast` `slow` `hurry` `rev` `iter` `iterBack` `palindrome` | |
| `every` `every'` `whenmod` `sometimesBy` `someCyclesBy` | `every` `lastOf`/`firstOf` `whenmod` `sometimesBy` `someCyclesBy` | `sometimesBy` décide par cycle |
| `degradeBy` `unDegradeBy` | `degradeBy` | pas de `unDegradeBy` |
| `jux` `juxBy` `off` `superimpose` `layer` `stut` `echo` | `jux` `juxBy` `off` `superimpose` `layer` `stut` | `echo` = `stut` |
| `euclid` `euclidInv` `euclidOff` `euclidFull` | `euclid` `euclidInv` `euclidOff` | `euclidFull` = `stack(euclid, euclidInv(f))` |
| `struct` `mask` `sew` `stitch` | `structPat` `mask("1 0 1 1")` | pas de `sew`/`stitch` |
| `rot` `shuffle` `scramble` `linger` `brak` `swingBy` `swing` | idem | |
| `fastGap` `compress` `zoom` `inside` `outside` `ply` `segment` | idem | |
| `chunk` `chunk'` | `chunk` | pas de `chunk'` |
| `arp` `rolled` `rolledBy` accords `c'maj` | idem | |
| `n` `note` avec noms de notes `c e g` | idem | octave 5 = 0 |
| `range` `irand` `rand` `sine` `perlin` `saw` `tri` `square` | `range_pat` `rand_pat` `sine` `perlin` `saw` `tri` `square` | `range`/`rand` clashent avec Base |
| `striate` `chop` `slice` `splice` `loopAt` | `striate` `chopp` | pas de `slice`/`splice`/`loopAt` |
| `nudge` `fix` `bite` `squeeze` `ur` `weave` `wedge` `ncat` `wchoose` `select` `pickF` | — | pas encore |
| `(|+|)` `(|*|)` arithmétique entre patterns | — | `stack` pour le parallèle |
| `setcps` `hush` `once` `solo` `mute` | `cps!` `:hush` `:solo` `:mute` | `once` : joue avec `T` |

- **Entrée MIDI** — pas de driver natif (voir `13-external-midi`).

S'il te manque quelque chose de précis, ouvre une issue.

## Antisèche rapide

```haskell
-- Tidal                              -- Ressac
d1 $ s "bd hh sn hh"                  -- @d1 "bd hh sn hh"
d1 $ s "bd*4" # gain 0.8              -- @d1 "bd*4" |> gain(0.8)
d1 $ every 4 (fast 2) $ s "bd"        -- @d1 :bd |> every(4, fast(2))
d1 $ jux rev $ s "bd hh sn hh"        -- @d1 "bd hh sn hh" |> jux(rev)
d1 $ s "bd" # n "0 3 5"               -- @d1 :bd |> n("0 3 5")
hush                                  -- :hush  ou  ,
```

`:tutorial` parcourt le cycle premier beat → évaluer → mute pour ceux qui
ne connaissent pas Tidal. Une fois fait, tout le reste est « traduire la
syntaxe avec ce tableau ».
