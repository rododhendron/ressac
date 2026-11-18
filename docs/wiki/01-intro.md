# Bienvenue dans Ressac

Ressac est un environnement de live-coding en Julia pour SuperCollider /
SuperDirt. Tu écris des **patterns** (mini-notation façon TidalCycles),
des **synths** (un DSL Julia compilé en SC), et la session en cours fait
du son à travers SuperDirt.



## L'écran

Un seul écran. **Les patterns sont à gauche et y restent** ; à droite, un
**volet** qu'on échange sans rien perdre de ce qui y était ouvert :

| Volet | Pour l'ouvrir | Ce qu'il montre |
|---|---|---|
| la fiche | par défaut, `:back` | la doc de ce qui est sous le curseur, et ce que fait la ligne `@dN` où il se trouve |
| le wiki | `gw`, `:wiki` | cette documentation, à côté du travail |
| un son | `gs` sur son nom, `:synth nom`, `:son` | le texte du synth ; dessous, sa DOC et son studio en onglets |
| l'explorateur | `gx`, `:explorer` | l'explorateur génétique de sons, par-dessus |

`:q` ferme le volet et rend le clavier aux patterns ; `:q` de nouveau
quitte. Les patterns continuent de jouer quel que soit le volet. Sur un
grand écran (200 colonnes et plus), le son s'ouvre entre les patterns et
la fiche au lieu de la remplacer.

Chaque ligne `@dN` dit ce qu'elle fait, sur la ligne elle-même : un signe
dans la marge, un fond qui s'allume au coup, et au bout de la ligne une
piste d'un cycle. Voir `07-scope`.

En haut, la **status line** : le tempo, les quatre temps du cycle, et
`● SC` quand SuperCollider répond. En bas, la **barre de touches** de
l'endroit où tu es, puis la dernière ligne du **journal** (`:log` le
déplie).

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

Le contexte est ce que porte la pane qui a le clavier :

- **les patterns** (le texte, la fiche, le wiki, le journal) : `e` évalue
  la ligne, `E` tous les blocs, `m` coupe, `K` montre la fiche, `Espace`
  ouvre les snippets — d'où qu'on soit de ce côté-là ;
- **un son** (son texte, sa DOC, son studio) : `T` l'entend, `D` le tient
  en drone, `Espace` ouvre les maillons du DSL, `U` l'envoie dans un
  pattern, `P` mesure l'élagage, `K` `X` `Y` mettent la DOC sur la fiche,
  l'explication, le graphe ;
- **l'explorateur** : `T` et `D` sur le candidat.

Les commandes, elles, valent partout ; celles qui parlent d'un son
(`:sculpt`, `:explain`, `:todsl`…) l'ouvrent d'abord à droite. `?` puis
`Tab` liste toutes les touches du contexte. `:reset` refait l'écran à neuf
en gardant le texte des patterns.

Les ponts : depuis un pattern, `gs` ouvre le son sous le curseur ; depuis
un son, `U` pose `@dN p"nom*4"` dans les patterns ; depuis l'explorateur,
`M` et `e` amènent un candidat dans le volet du son.

## Se repérer

| Touche   | Ce qu'elle fait                                         |
|----------|---------------------------------------------------------|
| `?`      | l'aide du contexte (les touches de la pane focalisée)   |
| souris   | poser le pointeur sur un mot souligné ouvre sa fiche de glossaire |
| `Espace` | leader — suivi d'une lettre, insère un snippet (pattern ou maillon DSL dans un synth) |
| `:`      | la ligne de commande (`:tap`, `:browse`, `:synth wob`…) |
| `Esc`    | quitter l'insertion ; deux fois en mode normal : quitter Ressac |
| `e`      | évaluer la ligne courante                               |
| `E`      | évaluer TOUS les blocs `@dN`                            |
| `m`      | mute / démute le slot sous le curseur                   |
| `,`      | hush (arrêt doux, les voix s'éteignent)                 |
| `!`      | PANIC — coupe toutes les voix SC immédiatement          |
| `:q`     | quitter                                                 |

La **barre de touches** en bas de l'écran montre toujours les touches
utiles à l'endroit où tu es (elle change avec la pane focalisée, en
insertion, après un Espace-leader, dans un modal…).

## Commandes à connaître

- `:tutorial` — le tutoriel pas à pas (il suit ce que tu fais)
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
- `:log` — déplie / replie le journal (1, 3, 10 lignes, replié)
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
  d'usage, et le studio sculpt
