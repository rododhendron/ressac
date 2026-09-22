# Patterns et mini-notation

Les patterns vivent dans la pane patterns sous forme de lignes
`@dN "..."`. `"..."` est la mini-notation : un petit langage compact
pour les rythmes.

## Tokens

```
~              silence à ce pas
_              prolonge le pas précédent d'un pas
bd             nom de sample / synth
bd:2           la deuxième variante de bd
[bd hh]        un groupe : subdivise un pas en plusieurs
<bd sn cp>     alterne : un token par cycle
bd*4           répète dans le temps (4 coups pendant un pas)
bd!3           répète le pas (3 copies côte à côte)
bd(3,8)        euclidien : 3 coups répartis sur 8 pas
bd(3,8,2)      euclidien tourné : 3-sur-8 décalé de 2 pas
bd?            laisse tomber à 50 % (déterministe, par hash)
bd?0.3         probabilité personnalisée 0..1
```

Tout se combine :

```
@d1 "<[bd*2] sn> ~ bd ~"
@d2 "hh(7,16)" |> gain(0.4)
```

## Chaîne d'effets (l'opérateur pipe)

Chaque ligne `@dN` est du Julia. `|>` enchaîne les combinateurs :

```
@d1 "bd hh sn hh" |> gain(0.8) |> lpf(2000) |> pan(0.3)
```

### Écriture façon Tidal (sans parenthèses)

Dans une ligne `@dN`, une fonction suivie de ses arguments séparés par des
espaces s'appelle toute seule, comme en Haskell :

```julia
@d1 n "0 3 7" |> s "superpiano" |> fast 2 |> gain 0.8
@d1 s "bd*2 [sn cp]" |> n "<0 3>"
@d1 every 4 rev "bd hh sn hh"
@d1 "bd hh sn hh" |> every 4 rev |> lpf 800
```

Règles : dans le groupe de tête, `f a b … x` vaut `f(a, b, …)(x)` (le
dernier jeton est le pattern) ; après un `|>`, `f a b` vaut `f(a, b)`. Une
fonction seule ou une valeur seule reste telle quelle. Une ligne qui ne
pose que des contrôles (`@d1 n "0 2 4"`) joue le son par défaut
(`Ressac._DEFAULT_SOUND[]`, `superpiano`). Les deux écritures se mélangent
librement : `@d1 n "0 3" |> s("bd") |> fast 2`. Un argument qui est
lui-même un appel garde ses parenthèses (`every 4 (fast(2)) "bd"` s'écrit
`every 4 fast(2) "bd"`).

Combinateurs disponibles :

**Transformations de pattern** (remodèlent le temps / les valeurs) :
- temps : `fast` `slow` `density` `hurry` `rev` `iter` `iterBack` `palindrome`
  `early` `late` `off` `swingBy` `swing` `fastGap` `compress` `zoom` `inside`
  `outside` `linger` `ply` `plyWith` `brak` `press` `pressBy` `truncp`
  `spaceOut` `rot`
- concaténation : `stack` `overlay` `cat` `slowcat` `append` `seq` `fastcat`
  `fastAppend` `timeCat` `ncat` `randcat` `wrandcat` `wedge`
- structure : `superimpose` `layer` `mask` `inv` `gate` `structPat` `sew`
  `stitch` `euclid` `euclidInv` `euclidOff` `euclidFull` `chunk` `chunkBack`
  `shuffle` `scramble` `mono` `binary` `binaryN` `asciip` `necklace`
- conditionnel : `every` `every(n, décalage, f)` `whenmod` `when` `whenT`
  `within` `ifp` `sometimes` `sometimesBy` `often` `rarely` `always` `never`
  `almostAlways` `almostNever` `someCycles` `someCyclesBy` `degrade`
  `degradeBy` `unDegradeBy` `lastOf` `firstOf` `fix` `unfix` `contrast`
- choix : `select` `selectF` `pickF` `squeeze` `spread` `fastspread` `spreadf`
  `spreadChoose` `choose` `chooseBy` `wchoose` `wchooseBy` `fit`
- accords : `arp` `arpeggiate` `rolled` `rolledBy` `toScale`
- échos : `jux` `juxBy` `stut` `echo` `echoWith` `stutter` `ghost` `ghostWith`
- samples : `striate` `striateBy` `chopp` `slice` `splice` `bite` `chew`
  `randslice` `loopAt` `smash`
- signaux : `sine` `cosine` `tri` `saw` `square` `perlin` `rand_pat` `irand`
  `brand` `brandBy` `range_pat` `rangex` `segment` `smooth` `quantise` `runp`
  `scan`
- arrangement : `weave` `weaveWith` `ur`
- `pure` `silence`

**Arithmétique** : `+ - * / %` entre deux patterns (structure des deux
côtés, le `|+|` de Tidal), entre un pattern et un nombre, ou avec une
chaîne : `n(p"0 3" + "<0 12>")`, `n(p"0 3" + 12)`. Entre deux
ControlPatterns les clés numériques communes se combinent. En pipe :
`add(:n, 12)`, `sub`, `mul`.

`:doc <nom>` donne la description et des exemples de chacune ; la
livedoc les montre dès que le curseur est dans l'appel.

**Contrôles** (paramètres par événement, en chaîne `|>`) :
- `s` (`sound`) `n` `note` (`up`) `gain` `speed` `pan` `degree`
- `begin_` `end_` `unit` `cut` `orbit` `nudge` `loop` `squiz` `midinote`
  `channel` `dry`
- `lpf` `hpf` `cutoff` `resonance` `bandq` `bandf`
- `room` `delay` `delaytime` `delayfeedback`
- `attack` `release` `hold` `sustain` `legato`
- `shape` `crush` `coarse` `vowel`
- `octave` `accelerate` `vibrato`
- `compress` `compressThreshold` `compressRatio`
- `pump(steps, depth)` — ducking de gain façon sidechain

Valeur numérique ou pattern : `gain(0.8)` est constant ; `gain("0.5 1
0.5 1")` varie au fil du cycle.

## Exemples de combinateurs

```julia
@d1 "bd hh sn hh" |> jux(rev)           # stéréo : gauche tel quel, droite inversée
@d1 "bd hh sn hh" |> sometimes(fast(2)) # un cycle sur deux en double vitesse
@d1 "hh*8" |> degradeBy(0.3)            # laisse tomber 30 % des coups (déterministe)
@d1 "bd hh sn hh" |> iter(4)            # tourne d'1/4 à chaque cycle
@d1 "bd hh sn hh" |> palindrome         # à l'endroit puis à l'envers
@d1 "bd hh sn hh" |> chunk(4, fast(2))  # un morceau par cycle passe en rapide
@d1 :pad |> pump(8, 0.7)                 # pompage sidechain 4 temps
```

## Notes, accords et arpèges

`n` et `note` acceptent des noms de notes comme Tidal (octave 5 = 0,
`s`/`#` dièse, `f`/`b` bémol) :

```julia
@d1 :pad |> n("c e g")           # 0 4 7
@d1 :pad |> n("cs5 df a4")       # 1 1 -3
```

Un accord s'écrit `racine'nom` dans la mini-notation : ses notes jouent
ensemble. Racine = nom de note ou nombre ; `chord_names()` liste les noms
(maj, min, dom7, min7, maj7, sus4, dim, aug, nine, m9, six, add9…).
Modificateurs Tidal : `'i` `'ii` renversements, `'o` ouvert, `'N` nombre
de notes.

```julia
@d1 :pad |> n("c'maj e'min a4'min7")
@d1 :pad |> n("0'dom7 5'maj")
@d1 :pad |> n("c'maj'ii")        # second renversement
```

`arp(mode)` égrène chaque accord dans son créneau : `up`, `down`,
`updown`, `downup`, `up&down`, `down&up`, `converge`, `diverge`,
`disconverge`, `pinkyup`, `pinkyupdown`, `thumbup`, `thumbupdown` ; le mode
peut être un pattern. `rolled` / `rolledBy(t)` décalent légèrement les
notes d'un accord comme une main sur un piano.

```julia
@d1 :pad |> n("c'maj e'min") |> arp("<up down>")
@d1 :pad |> n("c'maj7") |> arp("converge") |> fast(2)
@d1 :pad |> n("c'maj") |> rolled
```

## Slots

Chaque `@dN` enregistre un pattern dans le slot `dN`. Ré-évaluer le
même slot le remplace. Pour arrêter un slot, commente-le (`# @d1 ...`)
et `:e` ré-évalue (les slots mutes sont sautés). Ou `:mute d1` de
n'importe où.

## Snippets

`:snip` (ou `Espace I`) ouvre le sélecteur. Les catégories tournent avec
Tab : **rythme** · **mélodie** · **fx** · **track** · **genre** ·
**référence**.

Genres disponibles : jersey, footwork, garage, trap, dnb, techno, house,
breakcore, drill, dembow, boombap, lofi_hiphop, phonk, witch_house,
bossanova.

Snippets de référence (insèrent des fiches commentées dans le buffer) :
cheat_combinators, cheat_controls, cheat_mini, cheat_commands,
cheat_pipes, helpers_tour.

## Modèles Espace-leader

`Espace` en mode normal, puis une lettre : un modèle avec des trous
s'insère. Tab passe d'un champ à l'autre, `i` remplit, `u` annule. Le
popup which-key liste les lettres possibles.

Où ça atterrit : un maillon `|> …` va **en fin de ligne** du bloc courant
(après ses lignes `|>`), une ligne complète `@dN …` va **sous le bloc**,
avec le premier numéro de slot libre déjà rempli ; un fragment
(`rev`, `bd(3,8)`) s'insère au curseur. Sur une ligne vide, tout
s'insère sur place.

Pour se guider : `K` sur un mot ouvre sa fiche dans la pane DOC à côté
(`:doc gain` aussi), `:wiki patterns` ouvre cette page en pane, la barre
du bas suggère quoi faire sur une ligne vide ou après un `|>`, et `:e`
signale un nom de son inconnu.

| Touche      | Insère                                        |
|-------------|-----------------------------------------------|
| `Espace d`  | `@d$1 "$2"`                                   |
| `Espace g`  | `\|> gain($1)`                                |
| `Espace l`  | `\|> lpf($1)`                                 |
| `Espace h`  | `\|> hpf($1)`                                 |
| `Espace p`  | `\|> pan($1)`                                 |
| `Espace f`  | `\|> fast($1)`                                |
| `Espace s`  | `\|> slow($1)`                                |
| `Espace r`  | `\|> room($1)`                                |
| `Espace n`  | `\|> n("$1")`                                 |
| `Espace e`  | `\|> every($1, $2)`                           |
| `Espace m`  | `\|> mask("$1")`                              |
| `Espace D`  | `\|> delay($1) \|> delaytime($2) \|> ...`     |
| `Espace c`  | `\|> cat(["$1", "$2"])`                       |
| `Espace S`  | `\|> stack("$1", "$2")`                       |
| `Espace v`  | `rev`                                         |
| `Espace E`  | `$1($2,$3)` — token euclidien                 |
| `Espace R`  | `$1($2,$3,$4)` — euclidien tourné             |
| `Espace J`  | `@d$1 "bd(3,8)" \|> gain($2)` — jersey        |

Actions (ouvrent un modal) :

| Touche      | Ouvre                                         |
|-------------|-----------------------------------------------|
| `Espace b`  | `:browse` (tous les sons)                     |
| `Espace L`  | `:lib` (librairie de synths)                  |
| `Espace I`  | `:snip` (snippets)                            |
| `Espace w`  | `:wiki`                                       |
| `Espace ?`  | l'aide                                        |

## Raccourcis en ligne de commande — `:s<verbe>`

Des chaînes rapides, ajoutées à la ligne courante :

```
:sg0.9      → " |> gain(0.9)"
:sl2000     → " |> lpf(2000)"
:sf2        → " |> fast(2)"
:sr0.5      → " |> room(0.5)"
:st010110   → " |> gate(p\"0 1 0 1 1 0\")"
```

Variantes : `:sn<verbe>...` met le snippet sur une nouvelle ligne en
dessous (indentée), `:s<verbe>...N` ajoute un saut de ligne à la fin.
