# Bienvenue dans Ressac

Ressac est un environnement de live-coding en Julia pour SuperCollider /
SuperDirt. Tu écris des **patterns** (mini-notation façon TidalCycles),
des **synths** (un DSL Julia compilé en SC), et la session en cours fait
du son à travers SuperDirt.



## L'écran de jeu

PLAY s'ouvre sur trois panes :

- **les patterns à gauche**, sur les deux tiers de la largeur ;
- **le wiki en haut à droite**, sur les trois cinquièmes de la hauteur ;
- **la doc vivante en bas à droite**, qui suit le curseur.

La doc vivante montre ce qui est sous le curseur, sans rien demander. Sur
une fonction, sa description et ses exemples. Sur un son, ce qu'il est,
ses variantes ou ses paramètres, une ligne d'usage prête à copier, et sa
source quand c'est un synth. Quand le curseur n'est sur rien de connu, la
dernière fiche reste plutôt que de clignoter.

`f` dans la pane doc la fige ou la remet à suivre. `Ctrl-w z` zoome
n'importe quelle pane, `:q` en ferme une.

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
3. **Première fois ?** Tape `:tutorial` pour la visite guidée de 5 minutes.
   Sinon :
   - `i` passe en insertion, tape une ligne
   - `Esc` puis `e` évalue la ligne courante, OU `E` évalue tout
   - `m` mute le slot sous le curseur, `,` arrête tout en douceur, `!` coupe tout

Le buffer de démarrage contient déjà `cps!(0.5)` + un pattern kick/clap/
charley : `Esc` puis `E` et tu entends quelque chose.

## Trois workspaces, trois façons de travailler

- **PLAY** (`Ctrl-1` / `:play`) — la pane **patterns** : du code Julia avec
  des slots `@dN`. Chaque slot envoie des événements à SuperDirt ; `e` évalue
  la ligne, `E` tous les blocs `@dN`. La tête de lecture surligne le token
  qui joue dans chaque `"…"`.

- **DESIGN** (`Ctrl-2` / `:design`) — la pane **synth** : DSL Julia par
  défaut (`.jl`) ou SuperCollider brut (`.scd`). `t` / `T` / `Espace`
  joue le synth (maintenir = rafale accélérée), `:w` sauve, `U` l'utilise
  dans un pattern.

- **EXPLORE** (`Ctrl-3` / `:explore`) — l'**explorateur** génétique de
  synths et le studio **sculpt** (les paramètres d'un son manipulés
  directement sur son onde).

Les ponts : depuis un pattern, `gs` ouvre le synth sous le curseur dans
DESIGN ; depuis un synth ou un sculpt, `U` pose `@dN p"nom*4"` dans PLAY.

## Se repérer

| Touche   | Ce qu'elle fait                                         |
|----------|---------------------------------------------------------|
| `?`      | l'aide du contexte (les touches de la pane focalisée)   |
| `Espace` | leader — suivi d'une lettre, insère un snippet          |
| `:`      | la ligne de commande (`:tap`, `:browse`, `:synth wob`…) |
| `Esc`    | quitter l'insertion                                     |
| `e`      | évaluer la ligne courante                               |
| `E`      | évaluer TOUS les blocs `@dN`                            |
| `m`      | mute / démute le slot sous le curseur                   |
| `,`      | hush (arrêt doux, les voix s'éteignent)                 |
| `!`      | PANIC — coupe toutes les voix SC immédiatement          |
| `:q`     | quitter                                                 |

La **barre de touches** en bas de l'écran montre toujours les touches
utiles à l'endroit où tu es (elle change avec la pane focalisée, en
insertion, après un Espace-leader, dans un modal…). La **status line**
en haut montre le mode, la surface focalisée et les workspaces.

## Commandes à connaître

- `:tutorial` — visite guidée interactive
- `:tap` — tape un rythme avec Espace ; Ressac détecte la période, règle
  le cps et écrit la ligne `@dN "…"`
- `:browse` — tous les samples / instruments / synths, avec recherche
- `:lib` — la librairie de synths : écoute + copie éditable (intégrés ou
  sauvés par toi). Inclut le kit 909.
- `:snip` — snippets selon le contexte (rythme / mélodie / fx / fiches).
  Tab change de catégorie.
- `:starter <genre>` — un starter pack : house, trap, lofi, dubstep,
  jungle, idm, hardcore, amapiano, witchhouse, ambient
- `:import chemin/vers/sample.wav` — ajoute ton audio au registre
- `:mixer` — vu-mètres par slot, mute / solo / gain
- `:save nom` / `:load nom` — instantanés de session dans `sessions/`
- `:log` — replie / déplie le journal (3, 10, 0 lignes)
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
