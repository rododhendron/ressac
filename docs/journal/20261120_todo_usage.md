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
