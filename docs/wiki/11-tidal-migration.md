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
| `s "bd" # gain 0.7`        | `s "bd" \|> gain 0.7`  ou `"bd" \|> gain(0.7)` |
| `n "0 3 5" # s "piano"`    | `n "0 3 5" \|> s "piano"`     |
| `every 4 rev $ s "bd"`     | `every 4 rev "bd"`             |
| `jux rev`                  | `jux rev`  ou `jux(rev)`       |
| `degradeBy 0.3`            | `degradeBy 0.3`                |
| `pat1 |+| pat2`            | `pat1 + pat2`  (structure des deux) |
| `n "0 3" |+ n 12`          | `n("0 3") \|> add(:n, 12)`  (structure de gauche) |
| `+|` `|-` `|*` `|/` `|%`   | `sub` `mul` en pipe, ou `+ - * / %` |
| `every 4 (fast 2)`         | `every 4 fast(2)`              |

L'écriture sans parenthèses (`n "0 3" |> s "bd" |> fast 2`) est du sucre
de la macro `@dN` : voir « Écriture façon Tidal » dans `02-patterns`. Les
parenthèses restent obligatoires pour un argument qui est lui-même un
appel (`fast(2)`) et hors d'une ligne `@dN`.

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

Règles de composition :
- `gain` × · `lpf` min · `hpf` max · `speed` × · `pan` / `n` / `room` /
  `delay` / `shape` : le dernier gagne. `add(:clé, x)`, `sub`, `mul`
  pour composer explicitement (`|+`, `|-`, `|*` de Tidal).
- Structure : un contrôle à valeur pattern (`n("0 1 2 3")`) découpe les
  événements aux intersections — c'est le `|>|` de Tidal (structure des
  deux côtés), pas son `#` (structure de gauche seule). C'est ce qui rend
  `:bd |> n("0 1 2 3")` musical : quatre coups. Idem pour `+ - * /`.

### Durée des notes : `delta` comme Tidal

Chaque événement part avec `cps`, `cycle` et `delta` (sa durée en
secondes), exactement comme Tidal. SuperDirt en déduit
`sustain = delta × legato` : `n("[0 3] 7")` joue deux notes courtes puis
une longue. `legato(2)` allonge, `sustain(0.2)` fixe en secondes. Un
synth utilisateur joué en direct suit la même règle dès que son SynthDef
a un paramètre `sustain` ; `T` (audition) garde les défauts du SynthDef.

### Hauteur des synths utilisateur

Un synth `@synth` joué sans effet SuperDirt part en direct vers
SuperCollider. Ressac traduit alors `n`, `note`, `octave` et `midinote`
en `freq` avec la convention Tidal (note 0 = do 5 = MIDI 60, `octave` 5
par défaut), à condition que le SynthDef déclare `freq` — les arguments
d'un `.scd` sont lus au chargement, ceux d'un `@synth` à la définition.
Si la hauteur porte un autre nom, `pitch = "midinote"` (ou `"note"`, ou
une clé en hertz) dans `[synths.<nom>]` de `plugin.toml`. Avec un effet
(`lpf`, `room`…), SuperDirt fait la même traduction lui-même.

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

Presque tout le vocabulaire est là, sous le même nom. Renommages forcés
par Julia (mot-clé ou clash avec `Base`) : `struct` → `structPat`,
`trunc` → `truncp`, `ascii` → `asciip`, `run` → `runp`, `chop` → `chopp`,
`rand` → `rand_pat`, `range` → `range_pat`, `chunk'` → `chunkBack`,
`every'` → `every(n, décalage, f)`, `iter'` → `iterBack`, `begin`/`end` →
`begin_`/`end_`, `while` → `sew(b, f(p), p)`.

| Famille Tidal | Ressac |
|---|---|
| temps : `fast` `slow` `hurry` `rev` `iter` `iter'` `palindrome` `ply` `plyWith` `swingBy` `swing` `inside` `outside` `rot` `linger` `trunc` `zoom` `compress` `fastGap` `press` `pressBy` `spaceOut` `early` `late` `off` | idem (`iterBack`, `truncp`) |
| concaténation : `cat` `slowcat` `fastcat` `timeCat` `randcat` `wrandcat` `append` `fastAppend` `slowAppend` `overlay` `stack` `wedge` `ncat` `seq` | idem |
| structure : `struct` `substruct` `mask` `inv` `sew` `stitch` `euclid` `euclidInv` `euclidOff` `euclidFull` `binary` `binaryN` `ascii` `necklace` `mono` `chunk` `chunk'` `shuffle` `scramble` `superimpose` `layer` | idem (`structPat`, `asciip`, `chunkBack`) — pas de `substruct` |
| conditionnel : `every` `every'` `whenmod` `when` `whenT` `within` `ifp` `sometimesBy` `sometimes` `often` `rarely` `almostAlways` `almostNever` `always` `never` `someCyclesBy` `somecycles` `degradeBy` `unDegradeBy` `fix` `unfix` `contrast` `while` | idem — `while` = `sew(b, f(p), p)` |
| aléatoire : `rand` `irand` `perlin` `brand` `brandBy` `choose` `chooseBy` `wchoose` `wchooseBy` `cycleChoose` `randslice` `select` `selectF` `pickF` `squeeze` | idem (`rand_pat`) |
| accumulation : `stut` `echo` `echoWith` `stutWith` `stutter` `off` `superimpose` `layer` `spread` `fastspread` `spreadf` `spreadChoose` `spreadr` `ghost` `ghostWith` | idem |
| samples : `chop` `striate` `striateBy` `slice` `splice` `bite` `chew` `loopAt` `smash` `randslice` `fit` `hurry` | idem (`chopp`) |
| harmonie : `arp` `arpeggiate` `arpg` `rolled` `rolledBy` `toScale` `scale` accords `c'maj` `n "c e g"` | idem — `scale(:major)` est un contrôle |
| signaux : `sine` `cosine` `tri` `saw` `square` `range` `rangex` `quantise` `smooth` `segment` `discretise` `run` `scan` | idem (`range_pat`, `runp`) |
| arrangement : `ur` `weave` `weaveWith` | idem |
| arithmétique : `|+|` `|-|` `|*|` `|/|` `|%|` ; `|+` `|*` … ; `#` | `+ - * / %` (structure des deux côtés) ; `add`/`sub`/`mul` en pipe (structure de gauche) ; `\|>` |
| mini-notation : `~` `[]` `<>` `{}%` `*` `/` `!` `@` `_` `.` `..` `?` `|` `,` `(k,n,r)` `:` `'` | idem — couverture complète |
| contrôles : `s` `sound` `n` `note` `up` `gain` `pan` `speed` `begin` `end` `unit` `cut` `orbit` `nudge` `loop` `squiz` `midinote` `channel` `dry` `legato` `sustain` `accelerate` `vowel` `cutoff` `resonance` `room` `size` `delay`… | idem (`begin_`, `end_`) ; `set(:size, x)` pour les rares absents |
| session : `setcps` `hush` `once` `solo` `mute` `xfade` `jump` | `cps!` `:hush` `T` `:solo` `:mute` — pas de transitions |
| `nTake` `numerals` `sec` `msec` `fix` avec fonctions d'état | pas encore |

- **Entrée MIDI** — pas de driver natif (voir `13-external-midi`).

S'il te manque quelque chose de précis, ouvre une issue.

## Antisèche rapide

```haskell
-- Tidal                              -- Ressac
d1 $ s "bd hh sn hh"                  -- @d1 s "bd hh sn hh"
d1 $ s "bd*4" # gain 0.8              -- @d1 s "bd*4" |> gain 0.8
d1 $ every 4 (fast 2) $ s "bd"        -- @d1 every 4 fast(2) "bd"
d1 $ jux rev $ s "bd hh sn hh"        -- @d1 jux rev "bd hh sn hh"
d1 $ n "0 3 5" # s "superpiano"       -- @d1 n "0 3 5" |> s "superpiano"
d1 $ n ("0 3" + "<0 12>") # s "bd"    -- @d1 n (p"0 3" + "<0 12>") |> s "bd"
hush                                  -- :hush  ou  ,
```

`:tutorial` parcourt le cycle premier beat → évaluer → mute pour ceux qui
ne connaissent pas Tidal. Une fois fait, tout le reste est « traduire la
syntaxe avec ce tableau ».
