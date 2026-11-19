# Refonte visuelle — « A + D » (2026-11-19)

L'écran était laid, et ce n'était pas le thème : des cadres partout (deux
panes côte à côte = un double mur), quatre boutons de fenêtre par pane, onze
touches de même poids en bas, les touches d'une fenêtre écrites trois fois,
des fenêtres que les lignes surlignées traversaient, et une couleur qui
venait du thème plutôt que du sens.

Six déclinaisons de l'écran de jeu ont été maquettées sur une grille de
terminal stricte (Helix, lazygit, btop, tracker, k9s, Charm). Retenu : **A
(Helix) + D (tracker)**. Les maquettes sont sur le canevas « Ressac — refonte
visuelle », page « A + D — la direction retenue ».

## Le système (`src/ui_style.jl`)

- **Des fonds, pas des cadres.** Le sol (où l'on écrit), puis trois surfaces
  de plus en plus claires : la ligne d'état, ce qui flotte, la ligne choisie.
- **Quatre niveaux de texte** : texte, secondaire, discret, trame.
- **Une couleur dit un état, jamais une identité** : orange = maintenant (le
  curseur, sa ligne, la tête de lecture, le mode), vert = ça joue, rouge =
  erreur, jaune = chaînes et avertissements, bleu = fonctions, violet = ce
  qu'on essaie sans l'écrire.
- **Une bande de titre** par zone (`_band!`) : le nom en gras — dans la
  couleur du mode quand la zone a le clavier —, la précision en secondaire.
- **Un filet vertical** entre deux panes ; rien autour.
- **Ce qui flotte recouvre et éteint** : une fenêtre vide son rectangle
  (`_clear_rect!`), prend le fond des surfaces (`_surface!`), et le reste de
  l'écran passe dans la couleur de la trame (`_ui_dim!`).

La palette est en couleurs 24 bits ; les thèmes de Tachikoma sont en 256
couleurs. Le thème `ressac` (par défaut) prend les codes les plus proches, et
la dernière passe d'une frame (`_ui_finish!`) les remplace par les couleurs
exactes. La même passe pose le fond sous toute cellule qui n'en a pas : c'est
elle qui rend Ressac maître de son fond, quel que soit celui du terminal.
Avec un autre thème (`:theme kokaku`), la palette est déduite du thème.

Piège rencontré : `TK.set_string!` garde le fond d'une cellule quand le style
qu'on lui donne n'en a pas. Écrire des espaces ne recouvre donc pas une ligne
teintée — d'où `_clear_rect!`, qui écrit les cellules directement.

## L'écran

- **En haut** : `RESSAC`, la session et les sons ouverts en onglets ; à
  droite ce qui joue (tempo, les quatre temps, cycle, SC, casque) et les
  états rares en pastille (REC, BOUCLE, TAP, COMMANDE).
- **En bas** : la ligne d'état — le mode en pastille, où l'on est, la
  position ; à droite six touches au plus et `? aide`. Dessous, le message.
- **La grille du cycle** (`slot_marks.jl`) : une colonne fixe à droite du
  texte des patterns. Un temps sur deux a un fond, sur toute la hauteur ;
  chaque ligne `@dN` y a sa piste nommée ; la tête de lecture la traverse de
  haut en bas ; son en-tête (`SL 1 · · · 2 · · ·`) est dans la bande de titre.
  Les notes d'un `n("0 3 7")` s'y lisent en chiffres. L'erreur d'une ligne
  s'écrit à la place de sa piste. La ligne du curseur garde toujours son
  texte entier : si elle arrive sur la grille, la grille s'efface sur elle.
- **La fiche** : une colonne de lecture (46 colonnes, pas un tiers d'écran),
  avec sous la fiche deux bandes — LIGNE (ce que fait la ligne du curseur) et
  EN JEU (tous les slots et leur état).
- **Le menu Espace** : un panneau en bas, sur toute la largeur, qui n'éteint
  pas le code.

- **Un son** : entre 165 et 200 colonnes, son texte et sa DOC sont côte à côte et les
  patterns se réduisent à une colonne ; plus étroit, la DOC repasse sous le
  texte. La DOC s'ouvre sur l'explication, qui commence par la **chaîne en
  tableau** (`chain_table_spans`) : un maillon par ligne dans l'ordre du
  signal, les modulateurs en retrait avec le réglage qu'ils animent, et —
  après `P` — une jauge de ce que chacun change à l'oreille.
- **Le menu Espace** est rangé par intention (`_LEADER_COLUMNS`) : écrire,
  transformer la ligne, ouvrir, faire.
- **L'explorateur** : des tuiles sur fond, celle du curseur en orangé.

- **Les fenêtres** (`tk_picker.jl`) : le champ de recherche et la ligne
  choisie ont le fond des lignes choisies ; les onglets marquent l'actif en
  orange souligné ; la table du mixer n'a plus de filets
  (`_datatable_render!` les efface après le widget). Dans la réserve, un
  motif rangé se voit sur la grille du cycle avant qu'on l'écoute : sa ligne
  est évaluée « pour voir » (`_pattern_of_line`), sans rien lancer.
- **La palette** sans saisie est rangée par nature (tes sons, tes motifs, les
  sons, les commandes, les fonctions), le plus joué en tête de chacune.
- **La DOC d'un son** a ses trois vues en onglets dans sa bande de titre.
- Une pane de lecture du côté des patterns (wiki, fiche, journal) montre
  d'abord ses propres touches dans la ligne d'état.

## Reste à faire

- Les descriptions des commandes dans la palette et dans la complétion de `:`
  (il n'y a pas encore de texte d'une ligne par commande).
- La fenêtre d'aide `?` en colonnes par intention, comme le menu Espace.
