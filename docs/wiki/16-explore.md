# L'explorateur : trouver un son sans savoir l'écrire

L'explorateur (`gx` ou `:explorer`) s'ouvre par-dessus l'écran et sert à
**chercher un son** plutôt qu'à l'écrire : il fait évoluer une population
de synths par sélection. Ce qu'on trouve finit dans la ligne qu'on jouait
(`Entrée`), dans l'éditeur (`e`, `M`) ou dans la réserve (`w`) — et se
retravaille ensuite dans son texte, à l'atelier (voir `03-synth-dsl`).

## L'explorateur en deux minutes

Une grille de neuf candidats. Chaque candidat est un **génome** : un
petit graphe d'UGens (sources, filtres, modulations, mise en forme) que
Ressac sait rendre en SynthDef. Le point de départ est un **archétype**
(`drone_grave`, `pluck`, `fm_bell`, `noise_perc`) ou une graine que tu
as sauvée.

```
Space    écoute le candidat sous le curseur (h j k l, flèches, clic, 1-9)
f / d    favorise / dévalue — c'est toi qui sélectionnes
n        génération suivante : les favoris se croisent et mutent
0        repart de la graine, population fraîche
```

Le geste de base est `Space`, `f` ou `d`, `n`. Trois ou quatre
générations suffisent souvent pour tomber sur quelque chose qui
n'existait pas au départ.

## Diriger la recherche

- `T` bascule entre **brew** (rebrassage large) et **tune** (réglage fin
  autour d'un ancre : la structure est gelée, seuls les paramètres
  bougent).
- `[` et `]` règlent le **rayon** de divergence : petit rayon, variations
  discrètes ; grand rayon, la structure change.
- `>` et `<` choisissent une **guidance perceptive** appliquée à chaque
  génération : `grave`, `aigu`, `sombre`, `brillant`, `sature`, `clair`.
  Le titre de la pane la rappelle.
- `R` re-diverge (vieux parents + bruit), `C` ajoute de la diversité
  chaotique, `G` **greffe** un bon coup connu (filtre, saturation,
  réverbe…) sur le candidat, `S` régénère les candidats muets.
- `Tab` change de stratégie de sélection, `g` ouvre les réglages GA
  (`j/k` ligne, `h/l` valeur).

## Les rôles d'usage : chercher « une basse »

`u` fait tourner un **rôle** : `basse`, `kick`, `lead`, `nappe`, `voix`.
Un rôle est une cible dans l'espace des descripteurs acoustiques
(centroïde, poids du grave, platitude, attaque, tenue, netteté de
hauteur). Quand un rôle est actif :

- `H` fait une **récolte** : un grand pool est rendu hors-ligne, mesuré
  en silence, et les meilleurs pour le rôle remplacent la génération.
  Il faut `sclang` sur la machine.
- `+` et `-` taguent le candidat comme bon ou mauvais exemple du rôle :
  la cible se déplace vers ce que tu aimes.

## Comprendre ce qu'on entend

- `x` **explique** le son : la chaîne de la sortie vers la matière, le
  rôle de chaque nœud, et pourquoi ça sonne comme ça. Dans cette vue,
  `j/k` parcourt les composantes, `Space` joue une composante seule,
  `V` montre son onde.
- `i` montre le DSL du candidat, `y` le copie.
- `V` ouvre son onde complète dans une pane, `L` sa lignée (qui descend
  de qui).
- `p` édite ses paramètres, `t` le tient en drone, `m` en fait un
  mini-clavier (`z x c v…`).

## Garder ce qu'on a trouvé

| Touche | Ce qu'elle fait |
|---|---|
| `Entrée` | ouvert sur un slot (voir plus bas) : **adopte** le candidat dans la ligne |
| `M` | écrit le candidat dans le texte principal (`@synth :candidat_N …`), sous le bloc du curseur |
| `e` | pareil, sous le nom que tu donnes — puis `e` sur le bloc le fait entendre, `:keep` le range |
| `w` | le sauve comme synth dans `plugins/user-synths/` |
| `s` | le sauve comme **graine** dans `plugins/synth-seeds/`, pour repartir de lui |
| `y` | copie le DSL |

Un synth sauvé se joue comme n'importe quel son : `@d1 :nom`.

## Chercher un son pour une ligne qui joue

`gx` sur une ligne `@dN` **qui joue** ouvre l'explorateur *sur ce slot* :
le candidat sous le curseur joue alors **dans le pattern**, à la place du
son de la ligne — même rythme, mêmes notes, mêmes effets. On choisit un
son dans son contexte, pas dans le vide. Le titre le rappelle : « un autre
son pour d2 ».

- se déplacer dans la grille change le son du slot ; `n` (génération
  suivante) aussi ;
- `Entrée` **adopte** : le candidat est rangé comme un son (`trouve`,
  `trouve2`… dans `plugins/user-synths/`), son nom remplace l'ancien dans
  la ligne, et la ligne est réévaluée. `gs` dessus l'ouvre pour le
  travailler ; `u` dans les patterns revient à l'ancien son ;
- sortir autrement (`:q`, `:back`) rend le son d'origine.

Sur une ligne qui ne joue pas, ou ailleurs, `gx` ouvre l'explorateur tout
court.

## Élaguer ce qu'on a trouvé

Un son trouvé par évolution traîne souvent des étapes qui ne s'entendent
pas. Une fois ouvert (`M`, `e`), `X` montre son explication, qui se
termine par une section ÉLAGAGE : les indices lus sur la structure (un
nœud hors de la chaîne, une saturation qui replie un signal déjà replié,
une source à 0 Hz…) y sont tout de suite. `P` **mesure** : le son est
rendu sans chaque étape, en un lot, et l'impact de chacune s'affiche du
plus faible au plus fort. `:prune` retire d'un coup tout ce dont l'impact
est sous 0,02 (`:prune 0.05` pour un seuil plus large) ; `dam` retire un
maillon à la main.

## Un parcours typique

1. `gx`, `Space` sur quelques candidats, `f` sur ce qui plaît, `n`.
2. `u` jusqu'à `basse`, `H` : la génération se remplit de basses.
3. `M` sur la meilleure : tirer `freq`, `rq`, l'enveloppe ; `n` pour
   glisser une saturation ; écouter à chaque coup.
4. `U` : le son est sauvé et joue déjà sur un slot. `gs`
   depuis ce pattern ramène à son synth quand il faut le retoucher.
