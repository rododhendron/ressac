# Maquettes — l'écran unique

Date : 2026-11-17. Suite de `20261117_experience_utilisateur_reflexion.md`.
Ce sont des dessins pour se figurer, pas des specs : les touches et les
libellés sont des propositions. Largeur 100 colonnes.

Invariants de toutes les maquettes :

- **les patterns sont à gauche et jouent**, quel que soit le volet ouvert ;
- `m` muet, `,` hush, `!` panic marchent partout, y compris par-dessus ;
- un volet se ferme avec `q`, et l'écran revient à la maquette 1.

Marge des patterns : `▶` joue · `▷` muet · `✎` modifié, pas encore évalué ·
`✗` en erreur · `◌` décalé de la grille.

---

## 1. Au repos : ce qui joue + la fiche

```
 RESSAC  ● SC  120 bpm  ▮▮▮▯  cycle 12                 NORMAL                   brin.txt  +
╭─ brin ─────────────────────────────────────────────────────╮╭─ CE QUI JOUE ──────────────────╮
│▶ @d1 p"bd bd bd bd"                                        ││ d1 ▮▮▮▮▮▯▯▯  bd               │
│▷ @d2 p"~ ~ cp ~"                                           ││ d2 ·         cp        muet   │
│✎ @d3 p"hh*8" |> gain(0.4)                                  ││ d3 ▮▮▮▯▯▯▯▯  hh      (ancien) │
│✗ @d4 :wob |> n("0 <3 5") |> lpf("<400")                    ││ d4 ·         —                │
│    └ lpf : « <400 » n'est pas fermé · d4 ne jouait pas     ││ d5 ▮▮▯▯▯▯▯▯  zorglub    ◌     │
│◌ @d5 :zorglub |> n("0 7")                                  │╰────────────────────────────────╯
│                                                            │╭─ FICHE · lpf ───────────────────╮
│                                                            ││ lpf(coupure)                   │
│                                                            ││ Filtre passe-bas : laisse      │
│                                                            ││ passer ce qui est sous la      │
│                                                            ││ coupure (Hz).                  │
│                                                            ││   |> lpf(800)                  │
│                                                            ││   |> lpf("<400 2000>")         │
│                                                            ││ voisins : hpf · bandf · djf    │
│                                                            ││ ○ pas encore essayé : djf      │
╰────────────────────────────────────────────────────────────╯╰────────────────────────────────╯
 e évaluer · m muet · gs son · gw wiki · Espace réserve · Ctrl-p tout                    ? aide
 ▎ d3 modifié — e pour l'entendre
```

- La colonne de droite : l'état des slots, puis la fiche du mot sous le
  curseur. Elle suit sans qu'on demande.
- « voisins » et « pas encore essayé » : l'invitation vers ce qu'on ne
  connaît pas (décision F). Une ligne, jamais plus.
- Status line : `● SC` dit que SuperCollider répond ; le nom de la session
  à droite, `+` si elle n'est pas sauvée.
- Le journal est une ligne ; il se déplie à la demande.

## 2. Le wiki à côté

`gw` (ou `K` deux fois sur un mot) remplace la colonne de droite ; `q` la
rend.

```
╭─ brin ─────────────────────────────────────────────────────╮╭─ WIKI · 02 patterns ───── q ───╮
│▶ @d1 p"bd bd bd bd"                                        ││ » Alternances                  │
│▷ @d2 p"~ ~ cp ~"                                           ││                                │
│✎ @d3 p"hh*8" |> gain(0.4)                                  ││ <a b c> joue un élément par    │
│                                                            ││ cycle.                         │
│                                                            ││                                │
│                                                            ││   p"bd <sn cp>"      ⏎ essayer │
│                                                            ││   p"<a b>*2"                   │
│                                                            ││                                │
│                                                            ││ » Rythmes euclidiens           │
│                                                            ││ …                              │
│                                                            │╰────────────────────────────────╯
╰────────────────────────────────────────────────────────────╯ d1 ▮▮▮▮▯ d2 · d3 ▮▮▯
 j k défiler · / chercher · ⏎ poser l'exemple dans un slot libre · q fermer             ? aide
```

- L'état des slots se replie en une ligne sous le volet : on ne perd
  jamais de vue ce qui joue.
- Un exemple du wiki se pose dans un slot libre d'une touche.

## 3. Le son : texte + studio allégé

`gs` sur un nom de synth. Le volet prend la moitié de l'écran.

```
╭─ brin ───────────────────────────────╮╭─ SON · wob ──────────────────── joue dans d4 ── q ───╮
│▶ @d1 p"bd bd bd bd"                  ││ @synth :wob (freq=110, sustain=0.5) begin           │
│▷ @d2 p"~ ~ cp ~"                     ││   saw(:freq)                                        │
│▶ @d4 :wob |> n("0 <3 5>")            ││   |> rlpf(sin_osc(2) |> range(300, 1800), 0.3)      │
│                                      ││   |> perc(0.01, :sustain)                           │
│                                      ││ end                                                 │
│                                      │├─────────────────────────────────────────────────────┤
│                                      ││  ▁▃▆█▇▅▃▂▁▁▂▄▆▇▆▄▂▁                                  │
│                                      ││ ▸ coupure basse   300   ━━━●━━━━━━━━                 │
│                                      ││   coupure haute  1800   ━━━━━━━━●━━━                 │
│                                      ││   vitesse LFO       2   ━●━━━━━━━━━━                 │
│                                      ││   résonance       0.3   ━━━●━━━━━━━━                 │
╰──────────────────────────────────────╯╰─────────────────────────────────────────────────────╯
 Tab texte ⟷ knobs · h l tirer · T entendre seul · :w sauver · gx explorer autour · a atelier
```

- Le studio ne garde que **l'onde et les knobs nommés**. Tirer un knob
  réécrit le nombre dans le texte, et le slot qui joue ce son change en
  direct.
- Tout le reste (échanger un UGen, insérer, recâbler, greffer, élagage,
  explication, graphe) passe derrière une seule touche, `a` — l'atelier.
- `:w` sauve ce qui a le focus : le synth ici, la session à gauche.

## 4. Explorer sur un slot

`gx` sur une ligne `@dN`. Par-dessus, en grand ; le pattern continue.

```
╭─ EXPLORER · un autre son pour d4 ─────────── @d4 … |> n("0 <3 5>") joue ────────────── q ───╮
│ ┌▸1 ─────────────────────┐ ┌ 2 ─────────────────────┐ ┌ 3 ─────────────────────┐            │
│ │ scie filtrée, LFO lent │ │ FM métallique          │ │ bruit résonant         │            │
│ │ ▁▃▆█▇▅▃▂▁              │ │ ▂█▁▇▂▆▁▅▂              │ │ ▃▄▃▅▄▃▄▅▃              │            │
│ │ ♪ dans d4              │ │                        │ │                        │            │
│ └────────────────────────┘ └────────────────────────┘ └────────────────────────┘            │
│ ┌ 4 ─────────────────────┐ ┌ 5 ─────────────────────┐ ┌ 6 ─────────────────────┐            │
│ │ deux scies désaccordées│ │ sinus plié             │ │ wob (l'original)       │            │
│ │ ▁▄▇█▆▃▁▂▅              │ │ ▁▂▄█▄▂▁▂▄              │ │ ▁▃▆█▇▅▃▂▁              │            │
│ └────────────────────────┘ └────────────────────────┘ └────────────────────────┘            │
╰─────────────────────────────────────────────────────────────────────────────────────────────╯
 h j k l choisir (d4 le joue) · + garder · - écarter · n nouvelle génération · ⏎ adopter · g réglages
```

- Se déplacer sur une carte la fait jouer **à la place du son de d4**,
  dans le pattern. Sortir sans adopter rend le son d'origine.
- Une carte dit ce qu'elle est en mots, pas en arbre d'UGens.
- Stratégies, énergie, clusters, rôles : derrière `g`.

## 5. La réserve : sons, motifs, sessions

`Espace` puis `r` (ou `Ctrl-p`). Une seule bibliothèque.

```
╭─ RÉSERVE ────────────────────────────────────────────────────────────────────────────── q ───╮
│  sons 45 · [motifs 12] · sessions 10 · recettes                          / chercher          │
│                                                                                              │
│ ▸ jersey de base      @d1 p"bd(3,8) cp(1,8,4)"                        il y a 3 jours         │
│   charley qui respire @d3 p"hh*8" |> gain(sine() |> range_pat(.2,.6)) hier                   │
│   basse wob           @d4 :wob |> n("0 <3 5>") |> lpf(900)            aujourd'hui            │
│   …                                                                                          │
╰──────────────────────────────────────────────────────────────────────────────────────────────╯
 Espace écouter · ⏎ poser dans un slot libre · 1-9 poser dans ce slot · d supprimer · r renommer
```

- **Un motif est une ligne `@dN` entière** : le pattern, le son, sa chaîne
  d'effets. C'est « sauver un slot ». Depuis l'éditeur : `Espace k` sur la
  ligne (keep).
- On écoute avant de poser.

Sessions, avec les verbes de vim :

| Geste | Effet |
|---|---|
| `:w` | sauve la session courante (demande un nom si elle n'en a pas) |
| `:w nom` | sauve sous ce nom |
| `:e nom` | ouvre une autre session (complétion sur les noms) |
| `:enew` | session vierge ; ce qui joue continue jusqu'au premier `E` |
| `:e #` | revient à la session précédente |

## 6. Hors grille

Deux gestes, tous deux réalisables avec le moteur actuel.

**a. Lancer un slot à la frappe.** `e` évalue sur la grille, comme
aujourd'hui. `ge` évalue *maintenant* : le cycle 0 du slot commence à
l'instant de la touche. Le slot garde le tempo mais pas la phase ; la marge
le signale par `◌`. `e` dessus le recale.

**b. La boucle.** `Espace o` ouvre une boucle sur le son sous le curseur
(ou le synth courant). On joue au clavier ; `Espace o` à nouveau la ferme
et elle rejoue aussitôt, écrite dans un slot :

```
│◌ @d5 :zorglub |> frappes(0.0, 0.13, 0.48, 0.71; cycles = 2)                                  │
```

Les instants sont gardés tels quels, sans les ramener à une grille de 16.
Deux façons de fermer :

- **calée** : la longueur est arrondie à un nombre entier de cycles ; les
  frappes flottent à l'intérieur, la boucle reste avec le reste ;
- **libre** : la longueur est celle qu'on a jouée ; la boucle glisse peu à
  peu contre la grille, comme deux pédales de loop.

Le texte reste la vérité : la ligne s'édite, se sauve dans la réserve, se
passe dans `fast`, `rev`, `every` comme n'importe quel pattern.
