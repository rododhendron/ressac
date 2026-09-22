# Les mathématiques de la musique

La musique n'est pas *décrite* par les mathématiques, elle en est
faite : une hauteur est un rapport, un rythme est une fraction, une
harmonie est une coïncidence de périodes. Cette page montre d'où vient
chaque objet de Ressac et donne des choses à essayer tout de suite.

Toutes les fonctions citées existent : `:doc <nom>` en donne la fiche,
`Ctrl-p` les cherche.

## Le temps est une fraction

Un cycle vaut 1. Tout le reste est une division de ce 1 : `"bd sn"`
découpe en deux moitiés, `"bd*3"` en trois tiers, `bd@2` prend deux parts
sur trois. Les durées sont des rationnels exacts, jamais des flottants,
donc `"[bd bd bd] sn"` retombe pile sur le temps même après mille cycles.

Deux voix qui divisent le cycle différemment se recroisent au **plus
petit commun multiple** de leurs pas :

```julia
@d1 "bd*3"      # trois coups
@d2 "hh*4"      # quatre coups
# Motif combiné : il se répète toutes les 12 subdivisions.
```

C'est la polyrythmie. Avec des nombres premiers, le motif met très
longtemps à se répéter — et c'est exactement ce qui le rend vivant :

```julia
@d1 "bd*5"
@d2 "hh*7"       # se recroisent tous les 35 pas
@d3 :pad |> n(primes_n(4))
```

Le polymètre pousse l'idée plus loin : chaque voix garde son **nombre de
pas** au lieu de sa durée.

```julia
@d1 "{bd sn, hh hh hh}"      # 2 contre 3, sans changer de tempo
@d1 "{bd sn cp}%4"           # 3 pas joués 4 par cycle : ça glisse
```

**À essayer** : `@d1 "{bd*2, hh*3, cp*5}"` et compte combien de cycles
passent avant que le motif se répète. Réponse : le PPCM.

## Les hauteurs sont des rapports

Doubler une fréquence donne la même note plus haut : c'est l'octave,
rapport 2. Les autres intervalles simples sont aussi des petits
rapports, et c'est leur simplicité qui les rend consonants — les
harmoniques des deux sons coïncident souvent.

| Intervalle | Rapport juste | Cents justes | Cents tempérés |
|---|---|---|---|
| octave | 2/1 | 1200 | 1200 |
| quinte | 3/2 | 701,96 | 700 |
| quarte | 4/3 | 498,04 | 500 |
| tierce majeure | 5/4 | 386,31 | 400 |
| tierce mineure | 6/5 | 315,64 | 300 |

```julia
ratio_to_cents(3//2)     # 701.955
cents_to_ratio(700)      # 1.4983 — la quinte tempérée, un poil plus courte
semitones(5//4)          # 3.86 : la tierce juste est plus basse que la tierce du piano
```

Le tempérament égal découpe l'octave en douze pas identiques, chacun de
rapport `2^(1/12)`. Il ne donne aucun intervalle juste sauf l'octave,
mais il permet de jouer dans toutes les tonalités avec le même
instrument. C'est un compromis, pas une vérité.

```julia
@d1 :pad |> note("0 4 7")                           # tierce tempérée
@d1 :pad |> note([0, semitones(5//4), semitones(3//2)])   # tierce juste
```

L'écart s'entend : les battements disparaissent sur l'accord juste.

Ressac sait construire d'autres découpages :

```julia
register_scale!(edo(:n19, 19))          # 19 pas égaux : les tierces sonnent mieux
register_scale!(bohlen_pierce())        # 13 pas dans une tritave (3:1), pas d'octave
register_scale!(from_ratios(:juste, [1//1, 9//8, 5//4, 4//3, 3//2, 5//3, 15//8, 2//1]))
@d1 :pad |> n(0:6) |> scale(:juste)
```

**À essayer** : la même mélodie en `:major`, en `:n19` et en `:juste`.
La mélodie ne change pas, la couleur change complètement.

## Pourquoi un son a un timbre : la série harmonique

Une corde vibre à sa fréquence `f`, mais aussi à `2f`, `3f`, `4f`… Ce
sont les harmoniques, et leurs amplitudes relatives font le timbre.

```julia
harmonics(6; fundamental = 110)   # 110, 220, 330, 440, 550, 660
```

Les rapports du tableau plus haut sont précisément les rapports entre
harmoniques : `3f/2f = 3/2`, la quinte. La consonance n'est pas une
convention, c'est un recouvrement de spectres.

**À essayer** : empiler les cinq premières harmoniques et entendre
apparaître une seule note plutôt que cinq.

```julia
@d1 :pad |> freq(harmonics(5; fundamental = 110)) |> gain(0.3)
```

## Les rythmes euclidiens

Répartir `k` coups le plus régulièrement possible sur `n` pas est le
même problème que répartir des temps morts dans un compteur — l'algorithme
de Bjorklund, qui est l'algorithme d'Euclide déguisé. Le résultat est le
rythme traditionnel de dizaines de musiques : `(3,8)` est le tresillo
cubain, `(5,8)` le cinquillo, `(7,16)` un motif ouest-africain.

```julia
euclid_steps(3, 8)     # [1,0,0,1,0,0,1,0]
@d1 "bd(3,8)"
@d1 "bd(5,8)"
@d2 "hh(7,16)"
@d3 "cp(3,8,2)"        # le même, tourné de deux pas
```

**À essayer** : `@d1 "bd(<3 5>,8)"` alterne deux rythmes traditionnels à
chaque cycle, et `@d1 "bd(3,8)" |> euclidInv(3, 8)` joue les silences.

## Le hasard, mais tenu

Un tirage plat sonne mécanique. Les lois de probabilité donnent des
formes différentes, et c'est la forme qui s'entend.

| Fonction | Ce que ça produit | Pour quoi |
|---|---|---|
| `uniform(a, b)` | toutes les valeurs également | déréglage neutre |
| `normal(μ, σ)` | groupées autour de μ | vélocité, micro-timing humains |
| `expo(λ)` | beaucoup de petites, rares grandes | durées, intervalles |
| `cauchy(x, γ)` | comme normal, avec des extrêmes | accidents qui ressortent |
| `bernoulli(p)` | vrai ou faux | masques, déclenchements |
| `poisson(λ)` | un compte entier | combien de coups dans un pas |
| `walk(pas)` | dérive lente | filtres, panoramique |
| `markov(T, états)` | enchaînements pondérés | suites de sons qui ont une grammaire |

```julia
@d1 "hh*16" |> gain(normal(0.8, 0.1) |> segment(16))     # humain
@d1 "hh*16" |> gain(uniform(0.5, 1) |> segment(16))      # machine déréglée
@d1 "hh*16" |> mask(bernoulli(0.7) |> segment(16))       # un coup sur trois saute
@d1 :pad |> lpf(walk(0.15; lo = 300, hi = 5000))         # le filtre respire
@d1 markov([[0.2, 0.8, 0], [0, 0.3, 0.7], [0.6, 0, 0.4]], [:bd, :sn, :hh])
```

Tous ces tirages sont **déterministes** : la valeur dépend du temps de
l'événement, pas d'un état caché. Le même cycle rejoué donne le même
son, ce qui permet de revenir en arrière sans avoir tout perdu.

**À essayer** : la même ligne de charleston avec `uniform` puis avec
`normal`. Rien ne change sur le papier, tout change à l'oreille.

## Le chaos : déterministe et imprévisible

Une suite chaotique est entièrement déterminée par son point de départ,
mais deux départs voisins divergent. On obtient une variation qui ne se
répète jamais sans être du bruit.

La suite logistique `x → r·x·(1 − x)` change de nature avec `r` :

```julia
logistic_map(2.5, 8)    # converge vers une valeur
logistic_map(3.2, 8)    # oscille entre deux
logistic_map(3.5, 8)    # quatre
logistic_map(3.9, 8)    # chaos
@d1 "hh*8" |> lpf(logistic_map(3.9, 8) .* 3000 .+ 300)
```

Les attracteurs continus vivent dans le plugin `chaos` (page
[14-chaos-reservoir](14-chaos-reservoir.md)) : Lorenz, Hénon, Rössler.

**À essayer** : faire varier `r` de 2,8 à 4 par pas de 0,05 et écouter le
moment où la régularité se casse. C'est la cascade de doublements de
période, et elle s'entend.

## Les courbes

L'oreille perçoit la hauteur et l'intensité de façon **logarithmique** :
passer de 100 à 200 Hz est le même intervalle que de 1000 à 2000 Hz. Une
rampe linéaire sur une fréquence sonne donc tassée en haut.

```julia
@d1 "hh*8" |> lpf(ramp(200, 4000) |> segment(8))        # tassée
@d1 "hh*8" |> lpf(expramp(200, 4000) |> segment(8))     # régulière à l'oreille
@d1 "hh*8" |> lpf(geom(200, 4000, 8))                   # la même, en liste
```

`curve` prend n'importe quelle fonction du temps :

```julia
@d1 "hh*8" |> pan(curve(t -> sin(2pi * t)^3) |> segment(8))
@d1 "hh*8" |> gain(curve(t -> 1 - t^2) |> segment(8))
```

## Suites et nombres

```julia
fib(8)          # 1 1 2 3 5 8 13 21 — proches du nombre d'or, jamais périodiques
primes_n(6)     # 2 3 5 7 11 13 — pour des cycles qui ne se recroisent pas
harmonics(8)    # la série harmonique
geom(200, 6400, 6)   # une progression géométrique
```

Une liste Julia est un pattern : elle devient une séquence d'un cycle.
`slowcat` en fait une alternance, un élément par cycle.

```julia
@d1 :pad |> n(fib(5))                 # les cinq valeurs dans le cycle
@d1 :pad |> n(slowcat(fib(5)))        # une par cycle
@d1 :pad |> n(tomini([[0, 3], 7]))    # ou repasser en mini-notation
```

**À essayer** : `@d1 :pad |> n(fib(7) .% 12)` — Fibonacci replié dans une
octave donne une mélodie qui tourne sans jamais boucler pareil.

## Aller et venir entre Julia et la mini-notation

| Depuis | Vers | Comment |
|---|---|---|
| chaîne | pattern | `p"bd sn"`, `pat("bd sn")` |
| liste, range | pattern (séquence) | `pat(0:7)`, ou directement `n(0:7)` |
| liste | pattern (alternance) | `slowcat(0:7)` |
| pattern | valeurs Julia | `patvals(p"0 3 7")` → `[0, 3, 7]` |
| liste Julia | mini-notation | `tomini([[0, 3], 7])` → `"[0 3] 7"` |

Les arguments numériques des combinateurs acceptent aussi un pattern :
`fast("<1 2>")`, `ply("<2 3>")`, `every("<2 4>", rev)`, `degradeBy("<0 0.5>")`.
Tout ce qui est un nombre peut donc devenir une suite dans le temps.

```julia
@d1 "bd sn" |> fast("<1 2 4>") |> ply("<1 2>")
@d1 :pad |> n(patvals(p"0 3 7") .+ 12)      # relire, transformer, rejouer
```

## Pistes d'exploration

1. **Polyrythmie première** : `@d1 "bd*5"` contre `@d2 "hh*7"`, puis
   ajoute `@d3 "cp*3"`. Combien de temps avant que ça se répète ?
2. **Le même motif, trois tempéraments** : `:major`, `:n19`, une gamme
   juste faite avec `from_ratios`.
3. **Humaniser** : `normal` sur le gain, puis sur le micro-timing avec
   `nudge`, et compare à `uniform`.
4. **Chaos contrôlé** : `logistic_map` sur le filtre, en faisant monter
   `r` cycle après cycle.
5. **Euclide partout** : mets `(k,n)` sur trois voix avec des `n`
   premiers entre eux, `@d1 "bd(3,8)" @d2 "hh(5,16)" @d3 "cp(7,12)"`.
6. **Série harmonique jouée** : empile `harmonics(6)` puis retire un
   partiel sur deux et écoute le timbre changer.
7. **Grammaire de batterie** : écris une matrice de Markov qui fait
   suivre la grosse caisse d'une caisse claire trois fois sur quatre.
8. **Fibonacci replié** : `n(fib(9) .% 12)` puis `|> scale(:minor)`.
