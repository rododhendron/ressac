# Bienvenue dans Ressac

Ressac est un environnement de live-coding en Julia pour SuperCollider /
SuperDirt. Tu écris des **patterns** (mini-notation façon TidalCycles),
des **synths** (un DSL Julia compilé en SC), et la session en cours fait
du son à travers SuperDirt.



## L'écran

Un seul écran, et **un seul texte** : les patterns et les sons s'y écrivent
ensemble, à gauche. À droite, un **volet** qui accompagne, et qu'on échange
sans rien perdre de ce qui y était ouvert :

| Volet | Pour l'ouvrir | Ce qu'il montre |
|---|---|---|
| la fiche | par défaut, `:back` | la doc de ce qui est sous le curseur, et ce que fait la ligne `@dN` où il se trouve |
| le wiki | `gw`, `:wiki` | cette documentation, à côté du travail ; `Tab` désigne un exemple `@dN` de la page, `Entrée` le pose dans tes patterns |
| la DOC d'un son | `K` `X` `Y` dans un son, `:son` | la fiche du mot, l'explication du son, son graphe — le texte du son, lui, est dans le texte principal |
| l'explorateur | `gx`, `:explorer` | l'explorateur génétique de sons, par-dessus |

`:q` ferme le volet et rend le clavier aux patterns ; `:q` de nouveau
quitte. Les patterns continuent de jouer quel que soit le volet. Sur un
grand écran (200 colonnes et plus), la DOC d'un son s'ouvre entre le texte
et la fiche au lieu de la remplacer.

Un **son** est un bloc `@synth :nom …` du texte. `gs` sur son nom, ou
`:synth nom`, l'y amène ; dès que le curseur est dedans, les touches sont
celles du son (voir plus bas, et `03-synth-dsl`).

Chaque ligne `@dN` dit ce qu'elle fait, sur la ligne elle-même : un signe
dans la marge, un fond qui s'allume au coup, et à droite du texte sa piste
dans la **grille du cycle** — une colonne où un temps sur deux a un fond, et
que la tête de lecture traverse de haut en bas. Voir `07-scope`.

L'écran n'a pas de cadres : une zone, c'est une bande de titre (dans la
couleur du mode quand elle a le clavier) et un filet qui la sépare de sa
voisine. La couleur dit un état : orange pour maintenant (le curseur, la
tête de lecture), vert pour ce qui joue, rouge pour une erreur.

En haut, ce qui joue : la session et les sons ouverts, le tempo, les quatre
temps du cycle, et `● SC` quand SuperCollider répond. En bas, la **ligne
d'état** : le mode, l'endroit où tu es, et les touches les plus utiles (le
reste est dans `?` et dans le menu `Espace`) ; dessous, la dernière ligne du
**journal** (`:log` le déplie).

## Tout retrouver : Ctrl-p

`Ctrl-p` ouvre la palette. On tape, elle filtre, `Entrée` fait ce qu'il
faut selon ce qu'on a choisi :

| Nature | Entrée fait… |
|---|---|
| `:` commande | la lance |
| ♪ son | l'insère au curseur |
| ƒ fonction | l'insère et ouvre sa fiche dans la pane DOC |
| ▣ pattern rangé | le recharge sur son slot |
| ◈ recette de synth | l'installe |
| ? page du wiki | l'ouvre en pane |

C'est le raccourci à retenir quand on ne sait plus où est quelque chose.

## Démarrage rapide

1. Lance SuperCollider avec le script de démarrage de Ressac
   (`just audio` ou équivalent — voir le README du projet).
2. Lance la TUI : `julia --project=. scripts/live.jl`
3. Le texte de départ contient `cps!(0.5)` et un pattern kick / clap /
   charley : `E` et tu entends quelque chose.
   - `i` passe en insertion, tape une ligne, `Esc` en sort
   - `e` évalue la ligne courante, `E` tous les blocs `@dN`
   - `m` coupe le slot sous le curseur, `,` arrête tout en douceur, `!` coupe tout
4. **Première fois ?** `:tutorial` ouvre une pane à côté des patterns, qui
   avance toute seule au fil de ce que tu fais.

## Le clavier suit ce que tu travailles

Le clavier est en couches : une touche descend les couches actives —
transitoire (saisie, leader, mode pane…), modale, pane focalisée,
**contexte**, partout — jusqu'à la première qui la connaît.

Le contexte suit le curseur :

- **les patterns** (le texte, la fiche, le wiki, le journal) : `e` évalue
  la ligne (`Entrée` : tout de suite, hors de la grille), `E` tous les blocs, `m` coupe, `K` montre la fiche, `Espace`
  ouvre les snippets — d'où qu'on soit de ce côté-là ;
- **un son** (le curseur dans un bloc `@synth`, ou dans sa DOC) : `e`
  l'évalue, `T` l'entend, `D` le tient
  en drone, `Espace` ouvre les maillons du DSL, `U` l'envoie dans un
  pattern, `P` mesure l'élagage, `K` `X` `Y` mettent la DOC sur la fiche,
  l'explication, le graphe ;
- **l'explorateur** : `T` et `D` sur le candidat.

Les commandes, elles, valent partout ; celles qui parlent d'un son
(`:explain`, `:prune`, `:format`, `:save`…) visent celui du curseur. `?` puis
`Tab` liste toutes les touches du contexte. `:reset` refait l'écran à neuf
en gardant le texte des patterns.

Les ponts : depuis un pattern, `gs` amène dans le texte le son nommé sous
le curseur ; depuis un son, `U` écrit un `@dN p"nom*4"` qui le joue ;
depuis l'explorateur, `M` et `e` écrivent un candidat dans le texte.

## Se repérer

| Touche   | Ce qu'elle fait                                         |
|----------|---------------------------------------------------------|
| `?`      | l'aide du contexte (les touches de la pane focalisée)   |
| souris   | poser le pointeur sur un mot souligné ouvre sa fiche de glossaire |
| `Espace` | leader — suivi d'une lettre, insère un snippet (pattern ou maillon DSL dans un synth) |
| `:`      | la ligne de commande (`:tap`, `:browse`, `:synth wob`…) |
| `Esc`    | revenir : quitter l'insertion, fermer une fenêtre. Ne quitte jamais Ressac |
| `Tab`    | en insertion : complète le mot ; sinon des espaces jusqu'au taquet. `\sigma` puis `Tab` écrit σ (`\tau` τ, `\alpha` α…) |
| `e`      | évaluer la ligne courante                               |
| `E`      | évaluer TOUS les blocs `@dN`                            |
| `m`      | mute / démute le slot sous le curseur                   |
| `,`      | hush (arrêt doux, les voix s'éteignent)                 |
| `!`      | PANIC — coupe toutes les voix SC immédiatement          |
| `:q`     | quitter (`:qa` tout de suite)                           |

La **barre de touches** en bas de l'écran montre toujours les touches
utiles à l'endroit où tu es (elle change avec la pane focalisée, en
insertion, après un Espace-leader, dans un modal…).

## Commandes à connaître

- `:tutorial` — le tutoriel pas à pas (il suit ce que tu fais)
- `:tap` — tape un rythme avec Espace ; Ressac détecte la période, règle
  le cps et écrit la ligne `@dN "…"`
- `:browse` — tous les samples / instruments / synths, avec recherche
- `:réserve` — tout ce qu'on a rangé, en quatre onglets (`Tab`) : les sons
  (`:lib`), les motifs, les sessions (`:sessions`), les recettes (`:snip`).
  `Espace k` y range la ligne `@dN` du curseur.
- `:starter <genre>` — un starter pack : house, trap, lofi, dubstep,
  jungle, idm, hardcore, amapiano, witchhouse, ambient
- `:import chemin/vers/sample.wav` — ajoute ton audio au registre
- `:mixer` — vu-mètres par slot, mute / solo / gain
- `:w nom` / `:e nom` / `:enew` — ranger la session, en ouvrir une autre,
  repartir d'une vierge (voir `05-cookbook`). La session, c'est le texte
  entier, sons compris
- `:save` (ou `Espace W`), le curseur sur un son — le range dans la réserve
  des sons, où les autres sessions le trouvent ; `:save nom` sur un bloc
  `@dN` range le pattern
- `:log` — déplie / replie le journal (1, 3, 10 lignes, replié)
- `println(x)` / `@show x` dans une ligne évaluée (ou dans un pattern qui
  joue) s'écrivent dans le journal, précédés de `›` — pour déboguer
- `:wiki` — cette documentation

## Pour aller plus loin

- `02-patterns` — la mini-notation (avec `?`, `_`, rotation)
- `03-synth-dsl` — le DSL de synthèse et ses recettes
- `04-keys` — toutes les touches, générées depuis le registre
- `05-cookbook` — recettes de sons et snippets de genres
- `09-samples` — ajouter tes propres samples
- `10-architecture` — les internes, le flux de données, qui possède quoi
- `11-tidal-migration` — si tu viens de TidalCycles
- `12-troubleshooting` — quand quelque chose ne marche pas
- `13-external-midi` — MIDI + OSC depuis tout ce qui parle OSC
- `14-chaos-reservoir` — générateurs chaotiques et patterns par réservoir
- `15-maths` — les mathématiques de la musique : temps, hauteurs,
  rythmes euclidiens, hasard tenu, chaos, et des pistes à essayer
- `16-explore` — l'explorateur génétique de synths, les rôles
  d'usage, et comment garder ce qu'on a trouvé
