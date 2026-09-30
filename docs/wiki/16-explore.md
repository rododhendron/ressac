# EXPLORE : trouver un son sans savoir l'écrire

Le troisième workspace (`Ctrl-3` ou `:explore`) sert à **chercher un
son** plutôt qu'à l'écrire. Deux outils s'y enchaînent : l'**explorateur**,
qui fait évoluer une population de synths par sélection, et le studio
**sculpt**, qui prend un son et le pétrit sur son onde. Ce qu'on trouve
finit dans un pattern (`U`), dans l'éditeur (`e`) ou dans la librairie
(`w`).

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
| `M` | ouvre le candidat dans le studio **sculpt** |
| `e` | exporte son DSL dans l'éditeur (pane synth, workspace DESIGN) |
| `w` | le sauve comme synth dans `plugins/user-synths/` |
| `s` | le sauve comme **graine** dans `plugins/synth-seeds/`, pour repartir de lui |
| `y` | copie le DSL |

Un synth sauvé se joue comme n'importe quel son : `@d1 :nom`.

## Le studio sculpt

`M` depuis l'explorateur, ou `:sculpt` sur un synth DSL ouvert
(`:sculpt nom` pour un fichier de `plugins/user-synths/`). En haut,
l'onde rendue hors-ligne ; en bas à gauche, les **knobs** du son groupés
par fonction (global, source, filtre, enveloppe, effet…) ; à droite,
l'explication, qui se met à jour à chaque changement de structure.

```
j / k        knob suivant / précédent        Tab   nœud suivant
l / h        tirer + / −  (maintenir accélère)   =     saisir une valeur
Space        jouer
```

L'onde se re-rend après chaque geste (`↻` pendant le rendu). Les knobs
sont teintés par **quartier** : ceux qui bougent l'onde de la même façon
partagent une couleur, et la vivacité dit la force du lien — le studio
apprend en t'écoutant tirer.

La structure aussi se sculpte, nœud par nœud (le nœud porteur du knob
est affiché, ‹RLPF · 3/21 o›) :

| Touche | Ce qu'elle fait |
|---|---|
| `o` / `O` | remplace l'UGen par le suivant / précédent du même rôle |
| `n` | insère un filtre après le nœud |
| `d` | retire le nœud (l'entrée passe au travers) |
| `i` / `I` | recâble l'entrée sur un autre nœud |
| `r` / `R` | change le taux (audio ⟷ contrôle) |
| `x` | duplique le nœud en parallèle |
| `m` | greffe un LFO sur le paramètre focalisé |

Et pour finir : `e` exporte dans l'éditeur, `U` **utilise** le son dans
un pattern (sauve, puis pose `@dN p"nom*4"` dans PLAY), `s` revient à la
vue d'onde, `<` / `>` défilent l'explication.

## Un parcours typique

1. `Ctrl-3`, `Space` sur quelques candidats, `f` sur ce qui plaît, `n`.
2. `u` jusqu'à `basse`, `H` : la génération se remplit de basses.
3. `M` sur la meilleure : tirer `freq`, `rq`, l'enveloppe ; `n` pour
   glisser une saturation ; écouter à chaque coup.
4. `U` : le son est sauvé et joue déjà sur un slot dans PLAY. `gs`
   depuis ce pattern ramène à son synth quand il faut le retoucher.
