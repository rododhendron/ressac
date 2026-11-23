# Ce que l'usage a fait remonter (2026-11-20)

Première vraie séance sur le nouvel écran, et une liste (`TODO.txt`). Ce qui
en a été fait, ce qui reste ouvert.

## Corrigé

- **Le curseur ne se voyait plus** en mode visuel ni en mode normal : la
  sélection et la teinte de la ligne du curseur repeignaient sa cellule.
- **Tab en insertion** n'écrivait rien quand il n'y avait rien à compléter
  (la couche d'insertion est exclusive : rendre la main ne menait nulle
  part). Il écrit des espaces jusqu'au taquet (2 colonnes). `\sigma` + Tab
  écrit σ.
- **Une touche maintenue** ne se répétait pas en insertion.
- **Échap ne quitte plus** Ressac (`:q`, `:qa`).
- **L'étendue d'un bloc** (`_logical_block_range`) compte les blocs
  `begin … end` / `do … end` par mots entiers hors chaînes et commentaires
  (la première version, par `occursin`, fermait un bloc sur `blend` ou sur un
  commentaire), remonte quand la ligne d'avant finit par `|>`, et repart de
  zéro à chaque ligne `@dN`.
- **`:format`** met vraiment un maillon par ligne ; **`o`** ouvre l'atelier
  sur une chaîne écrite en une ligne et sur la ligne `@synth`.
- **`m` puis `m`** sur un slot lancé par `Entrée` le relance de la frappe.
  Couper un slot libère aussi les voix des synths nommés dans `s("…")`.
- **`:e` / `:e!`** dans le texte d'un son relisent ce son.
- **Les fiches** : celle d'une fonction du langage des sons montre sa vraie
  signature (lue sur ses méthodes), plus celle de l'UGen ; `saw` dans un son
  n'est plus le `saw` des patterns ; les fiches de paramètres (`rq`,
  `velocity`…) disent qu'elles ne sont pas des fonctions. Un test échoue si
  une fiche documente une fonction qui n'existe pas.
- **Réservoirs** : « Vector cannot be resized concurrently » venait de ce
  que l'interface (la grille, depuis la refonte) interrogeait le pattern en
  même temps que le scheduler, et faisait donc avancer le réservoir depuis
  deux fils. L'interface interroge maintenant par `preview_query`, et une
  source à état se construit par `stateful_pattern` (une question à la
  fois ; regarder ne fait pas avancer). Une chauffe en fond compile les
  réservoirs et leurs routes au lancement.
- **Le drone** retire l'enveloppe de note au lieu de la laisser s'éteindre.
- **La ligne de commande** : les flèches se promènent dans les propositions.
- Le titre du texte d'un son dit `SON · nom` (il disait `SYNTH`).

## Ouvert

- Voir ce qui joue dans le texte même (à la façon de Strudel : notes qui
  s'allument, roue des hauteurs) — une idée à maquetter, rien de fait.
- Brancher des réservoirs entre eux existe (`couple`, `connect!`), piloter
  l'entrée par un oscillateur aussi (`drive = sine() |> range_pat(…)`). Un
  vrai *readout* appris n'existe pas : les routes lisent l'état directement.
- Moduler un son en direct passe par ses arguments (`D`, pane MODULATION,
  ou `set(:arg, …)` depuis un pattern sur un slot `drone()`).

## Suite, le soir même

- **Démute d'un slot lancé par `Entrée`** : il revient calé sur la frappe
  d'origine (son cycle 0 n'a pas bougé), pas sur l'instant du démute.
  `slot_offgrid` garde la phase de chaque slot hors grille.
- **`println` / `@show`** : la sortie standard, que Tachikoma détourne
  pendant que l'écran est tenu, s'écrit dans le journal (lignes `›`).
- **Un son vit dans le texte principal** (`app_sound.jl`) : `M` / `e` de
  l'explorateur et `e` d'une onde y écrivent un bloc `@synth` ; `:keep`
  sur ce bloc range le son, `:format` et `K` y travaillent. Le volet du
  son (texte + DOC) existe encore pour `gs` / `:synth` ; l'atelier, `T`,
  `D`, l'explication et le graphe ne connaissent encore que lui — à porter
  sur le bloc du curseur si cette direction est la bonne.
- **Maquettes de la visualisation dans l'éditeur** : rouleau, roue, dans la
  ligne, signal — https://claude.ai/artifact/GawwcREwB56kGBnxDTKV8v

## Le 21 : un seul texte

Décision de Rodolphe : tout passe dans le pane principal (« sur un petit
écran, plusieurs panes, on ne lit plus rien »).

- **Il n'y a plus de texte de son à droite.** Un son est un bloc `@synth`
  du texte (`app_sound.jl` : `Sound` = nom + éditeur, ses lignes se
  retrouvent à l'usage). `gs`, `:synth nom`, la librairie, l'explorateur
  l'y amènent. Disparus : les onglets de sons, `Tab` patterns ⟷ synth,
  `gt` / `gT`, `:tabs`, `:test-raw`, la conversion `:todsl` sur place.
- **Le mode suit le curseur** : dans un bloc `@synth`, `_focused_role` dit
  `:synth`, donc le mode est SON et les touches sont celles du son (`e`
  évalue, `T`, `D`, `o` / `&`, `K` `X` `Y`). Le titre et la ligne d'état
  disent `SON · nom`.
- **`:save`** (alias `:keep`, et `Espace W` dans un son) range ce qui est
  sous le curseur : le son, ou le pattern d'un bloc `@dN`. `:w` et `:e`
  ne parlent plus que de la session.
- **Le volet `:son`** n'est plus que la DOC du son (fiche, explication,
  graphe, et la MODULATION en onglet) ; elle s'ouvre sans prendre le
  clavier. La fiche est plus large (62 colonnes, 42 % au plus).
- Une disposition sauvée d'avant, avec une pane d'édition de son, n'est
  pas reprise : l'écran est rebâti autour du texte.
- Reste : un drone tenu sur un son dont on supprime le bloc continue
  jusqu'à `!` ou `x` dans la MODULATION. La visualisation dans l'éditeur
  (choix : elle suit le curseur ; piste des pixels derrière le texte,
  `TK.render_rgba!` avec `z = -1` dans kitty) n'est pas commencée.

## Le 21, suite : la grille en pixels

- `pixel_layer.jl` : dans kitty, la grille du cycle est une image posée
  SOUS le texte (z très bas : kitty la dessine sous les cellules qui ont un
  fond, donc tout ce qui flotte la cache ; `_ui_finish!` laisse sans fond
  les cellules de la zone, `_PIXEL_HOLE`). Temps, pistes à la note près
  (longueur, hauteur dans la ligne), tête de lecture au pixel, rouleau du
  slot du curseur en bas. `_render_slot_marks!` remplit la scène,
  `_paint_scene` est pure et testée au pixel. `:pixels` bascule ; sans
  protocole graphique, la grille en caractères reste.
- **Pas vu dans un vrai terminal** : seule l'image peinte a été regardée
  (hors terminal). À vérifier dans kitty : que le texte passe bien dessus,
  que rien ne scintille, que les menus la cachent.
- Un drone tenu sur un son est relâché quand son bloc quitte le texte.
- Retour de Rodolphe : la grille en pixels marche. Corrigé : elle passait
  par-dessus le menu Espace (une surface déclarée par `_surface!` n'a pas
  de fond avant `_ui_finish!`, qui le lui refusait dans la zone). Ajouté :
  `|> pianoroll()` et `|> pitchwheel()` — le visuel se demande dans le
  pattern, comme dans Strudel (fonctions identité ; l'interface lit leur
  nom dans le texte qui joue).

## Le 21, soir : des rangées sous les slots, et le graphe de calcul

- `row_layout.jl` : le texte s'écarte sous un slot qui joue. L'éditeur de
  Tachikoma dessine serré, `_shift_rows!` descend les lignes ; tout ce qui
  convertit ligne du texte ⟷ ligne d'écran passe par `_gap_before` /
  `_text_row_at` (souris, sélection, flash, complétion fantôme, signes).
  Une rangée pour les réglages du bloc (une réglette par nombre connu), six
  pour le visuel demandé. `:rangées` referme.
- Les visuels demandés dans le pattern s'ouvrent sous leur slot, sur la
  largeur du texte (une image par visuel, devant celle de la grille) :
  `pianoroll`, `punchcard`, `pitchwheel`, `spiral`, `scope` (la sortie
  générale ; l'évaluation allume `:scope wave`). Le rouleau du slot du
  curseur reste au bas de la grille quand il n'a rien demandé.
- `_cascade_definitions!` : réévaluer une définition reprend celles qui la
  lisent, de proche en proche, puis les slots. Pas les blocs qui lisent ce
  qu'ils définissent ; une fonction n'est pas réévaluée mais ce qui
  l'appelle l'est.
- Toujours pas vu dans kitty par moi : les visuels sous les slots sont
  vérifiés par l'image peinte hors terminal.
- **Le graphe de calcul est pur** (demande de Rodolphe : « il faut le voir
  comme un DAG »). `_calc_nodes` / `_calc_plan` / `_calc_run!` : un nom
  défini plusieurs fois a des versions, un bloc lit celle du dessus, donc
  pas de boucle ; quand un nom est repris, toute sa chaîne est rejouée
  depuis sa première définition (`n = n + a` repart de `n = 0`). `e` sur
  un bloc rejoue d'abord ce qu'il lui faut, puis lui, puis ce qui en
  dépend. Un bloc qui se lit sans définition au-dessus n'est pas rejoué
  par la cascade (avertissement).
- Un bloc qui se lit lui-même sans définition au-dessus ne s'évalue plus du tout (`e`, `E`, cascade) : pas de graphe, pas d'évaluation — l'erreur dit quoi écrire.
