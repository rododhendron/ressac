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

Combinateurs disponibles :

**Transformations de pattern** (remodèlent le temps / les valeurs) :
- `fast` `slow` `density` `rev` `every` `stack` `cat` `mask` `gate`
- `jux` `juxBy` `off` `degrade` `degradeBy`
- `sometimes` `often` `rarely` `sometimesBy`
- `palindrome` `iter` `chunk`
- `pure` `silence`

**Contrôles** (paramètres par événement, en chaîne `|>`) :
- `gain` `speed` `pan` `n` `degree`
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
s'insère au curseur. Tab passe d'un champ à l'autre. Le popup which-key
liste les lettres possibles.

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
