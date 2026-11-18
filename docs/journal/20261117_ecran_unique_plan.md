# L'écran unique — plan

Date : 2026-11-17. Décisions : `20261117_experience_utilisateur_reflexion.md`
(parties 7 et 8). Maquettes : `20261117_maquettes.md` et le canevas (direction
D). Épreuve de l'atelier : `20261117_atelier.md`.

## Règles du chantier

- Chaque étape laisse une app jouable et une suite verte.
- Une case n'est cochée que si c'est fait **et** testé. Les écrans se
  testent par captures (`Tachikoma.TestBackend`, comme `scripts/tui_shot.jl`)
  et les gestes par `Tachikoma.update!`.
- Ce qui est remplacé est supprimé dans la même étape, pas laissé à côté.
- Après tout changement de touches : régénérer `docs/wiki/04-keys.md`.
- Ce qui dépend d'une mesure de l'étape 0 est marqué ⚑ : le plan se
  réajuste là si la mesure est mauvaise.

---

## Étape 0 — Mesurer avant de bâtir

Trois inconnues conditionnent des choix plus loin. Rien d'autre que des
mesures et une note de résultats (`20261117_mesures.md`).

- [ ] **E0.1 — Temps pour refaire un son.** De la frappe à la première note
  du nouveau SynthDef, sur un son en pipes et sur un export de
  l'explorateur. Demande SuperCollider lancé (hors suite par défaut).
  *Seuil* : sous une double croche à 120 bpm (125 ms), parcourir une liste
  de maillons paraît vivant ; au-delà, l'atelier attend une touche pour
  faire entendre.
- [ ] **E0.2 — Les signes dans kitty.** `𝅝 𝅗𝅥 𝅘𝅥 𝅘𝅥𝅮 𝅘𝅥𝅯 𝅘𝅥𝅰 𝄻 𝄼 𝄽 𝄾 𝄿 ♯ 𝄐 𝆔` : largeur d'une
  cellule, lisibles à la taille du texte. À regarder par Rodolphe.
  *Sinon* : famille « transport » par défaut, solfège en option.
- [x] **E0.3 — La ligne éclairée dans Tachikoma.** Peut-on donner un fond à
  une ligne de `CodeEditor` par-dessus la coloration, et le faire varier à
  chaque image sans tout redessiner ? Coût par image avec 12 slots.
  *Sinon* : seul le signe change d'éclat.
- [x] **E0.4 — Égalité des 18 `.scd` convertis.** `just test-user-synths`
  après conversion : le SC rendu est-il le même ?

## Étape 1 — L'état de chaque ligne

Le socle : savoir, pour chaque ligne `@dN`, ce qu'elle fait. Aucun
changement d'écran encore, donc sans risque.

- [x] **E1.1 — `SlotState`** par slot : joue, muet, modifié, en erreur,
  tenu, hors grille, au casque. Calculé à partir du scheduler et du texte.
- [x] **E1.2 — « Modifié ».** Le texte évalué de chaque bloc est gardé ;
  « modifié » = le bloc courant en diffère (`_logical_block_range`).
- [x] **E1.3 — L'erreur sait où elle est.** Une évaluation qui échoue, ou
  un slot retiré par `_evict_faulty_slot!`, garde : la ligne, la cause en
  une phrase, et si un ancien pattern continue de jouer.
- [x] **E1.4 — Densité.** Le nombre de coups du cycle courant par slot (mis
  en cache par cycle), d'où la valeur de note.

Tests : `test_slot_state.jl` — un cas par état, plus les transitions
(évaluer efface « modifié », corriger efface l'erreur).

## Étape 2 — L'écran unique

- [x] **E2.1 — Un seul workspace.** PLAY / DESIGN / EXPLORE disparaissent
  comme écrans. Restent : la pane patterns à gauche, une colonne à droite
  qui est un **volet** (fiche par défaut ; wiki ; son), et l'explorateur
  par-dessus. `app_modes.jl`, `app_synth_workspace.jl` et les commandes
  `:play` `:design` `:explore` (et leurs `!`) sont supprimés ; les scopes de
  touches `:mode_*` deviennent des scopes de volet.
- [x] **E2.2 — La marge.** Signe de l'état (E1) et fond de ligne ⚑ E0.3.
  Famille de signes dans la config (`ui.marks`), repli automatique ⚑ E0.2.
  `:calme` fige tout.
- [x] **E2.3 — L'erreur sur la ligne.** Au bout de la ligne fautive, à la
  place de la piste (l'éditeur de Tachikoma ne sait pas insérer une ligne
  qui n'est pas dans le texte). Le message entier ira dans la fiche (E2.5).
- [x] **E2.4 — La piste au bout de la ligne.** Un cycle, alignée sur la
  rangée de la première ligne du bloc. Raccourcit puis se cache si la ligne
  est longue ; densité au-delà d'un coup par colonne ; bande pour un drone ;
  trait de début de boucle pour un slot hors grille. Reprend l'interrogation
  de `pane_notes.jl`.
- [x] **E2.5 — La fiche.** *(fait : l'état du slot du curseur, ses notes
  exactes, l'erreur entière ; reste « voisins » et « pas encore essayé »,
  qui attendent E4.3.)* Suit le curseur (existant), plus « voisins » et
  « pas encore essayé » ⚑ E4.3.
  Sur une ligne `@dN` : l'erreur entière s'il y en a une, et les notes
  exactes que joue le slot (l'ancien aperçu `♪ 1 1 2 3 5`, que la piste ne
  donne qu'en hauteurs relatives).
- [x] **E2.6 — Le wiki dans le volet.** `gw` l'ouvre, `:q` le rend.
- [ ] **E2.6b — Poser un exemple du wiki** dans un slot libre : demande un
  curseur d'exemple dans la pane (`Tab` au suivant, `Entrée` le pose).
- [x] **E2.7 — Le chrome.** Status line avec `● SC` (le serveur répond-il),
  le nom de la session et `+` si non sauvée. Journal sur une ligne,
  dépliable. Le message d'accueil permanent disparaît.
- [x] **E2.8 — Grand écran.** Au-delà d'une largeur seuil, le son s'ouvre
  entre les patterns et la fiche au lieu de la remplacer.

### E2.1 — conception retenue (2026-11-18)

On garde le gestionnaire de workspaces et son arbre de panes (scissions,
redimensionnement, zoom) ; on n'en garde qu'**un** workspace.

- Racine : `Container(:h)[patterns, volet]`. Le volet est un sous-arbre
  qu'on échange ; les sous-arbres déjà ouverts sont gardés (`m.volets`),
  donc passer au wiki ne perd pas les sons ouverts.
- Sortes de volet : `:fiche` (DocPane qui suit, par défaut), `:wiki`,
  `:son` (`Container(:v)[texte du synth ; feuille à onglets DOC + STUDIO]` —
  le studio reste, en onglet, tant que E5 ne l'a pas remplacé : il porte le
  génome que lisent l'explication et le graphe), `:explorer` (une feuille,
  zoomée d'office).
- `_open_volet!(m, sorte)` / `_close_volet!(m)` (retour à `:fiche`, focus
  aux patterns) dans `app_volet.jl`. Les appels à
  `_switch_workspace_named!(m, "DESIGN" | "PLAY" | "EXPLORE")` deviennent
  ces deux fonctions.
- Le « mode » (`:play` / `:design` / `:explore`) reste comme contexte de
  touches, mais se lit sur la pane focalisée, plus sur un nom de workspace.
  Les tables de commandes par mode et `_mode_bridge!` disparaissent : toute
  commande vaut partout.
- Grand écran (≥ 200 colonnes) : `:son` s'insère entre patterns et fiche.
- Commandes : `:play` `:design` `:explore` et leurs `!` supprimées ;
  `:synth nom`, `:wiki`, `:explorer`, `:back` (ferme le volet), `:reset`
  (refait l'écran). `:q` dans un volet le ferme.
- Disposition sauvée d'avant (trois workspaces) : on en récupère le texte
  des patterns et les sons ouverts, pas la forme.

Supprimés : la bande des workspaces, le bandeau des slots (la piste au bout
de chaque ligne le remplace), le message d'accueil permanent. Le chapitre
« son » du tutoriel et la page 01 du wiki sont réécrits. La pane MODULATION
reste, rangée en onglet sous le texte du son, jusqu'à ce que E5 la remplace.

Tests : captures de référence à 140×40, 200×54 et 266×72 ; un test par
règle (« la piste est sur la rangée de sa ligne », « l'erreur est sous sa
ligne », « un volet fermé rend la fiche »).

Risque : la charge visuelle. À juger sur l'app réelle dès E2.4 ; la piste
se coupe d'une touche si elle gêne.

## Étape 3 — Sessions et réserve

- [x] **E3.1 — Les verbes de vim.** `:w` sauve ce qui a le focus (la
  session à gauche, le son dans le volet) ; `:w nom`, `:e nom` (complétion),
  `:enew`, `:e #`. Ce qui joue continue jusqu'au premier `E`.
- [x] **E3.2 — Au démarrage** : le dernier texte, en silence. Le buffer
  d'accueil seulement au tout premier lancement.
- [x] **E3.3 — La réserve.** Une seule bibliothèque à onglets : sons,
  motifs, sessions, recettes. `Espace` écoute, `Entrée` pose. Remplace
  `:lib`, `:patlib`, `:sessions`, `:snip`, `:starter` (qui restent comme
  alias vers leur onglet).
- [x] **E3.4 — Ranger une ligne.** `Espace k` sur un `@dN` : le motif
  entier, son et effets compris.

Tests : aller-retour sauver / ouvrir / vierge ; poser un motif dans un slot
libre et dans un slot choisi.

## Étape 4 — Un seul langage, lisible

- [x] **E4.1 — Zéro SuperCollider brut** ⚑ E0.4. *(Fait : l'éditeur ne
  travaille plus qu'en DSL — un `.scd` s'ouvre converti, `:w` range en `.jl`,
  sccode convertit à l'arrivée ou refuse. Les 18 `.scd` de `user-synths`
  ont leur `.jl` à côté, non suivi par git ; les `.scd` restent comme
  archives, ignorés par le chargeur. Supprimer les uns et suivre les autres
  est une décision de dépôt laissée à Rodolphe.)* Les 18 `.scd` convertis ;
  l'import sccode convertit à l'arrivée ou refuse avec la raison ; `:sc`
  n'ouvre plus de `.scd`. Le chemin `.scd` de l'éditeur est supprimé.
- [x] **E4.2 — Les nombres.** Trois décimales, notation scientifique au
  besoin, par `sc_num` et un pendant côté DSL. À l'export de l'explorateur,
  à la conversion, et une passe sur les fichiers existants.
- [x] **E4.3 — Compter l'usage.** Chaque nom documenté d'un bloc évalué avec
  succès est compté (`usage.toml`). D'où le classement de la complétion et
  « pas encore essayé ».
- [x] **E4.4 — Pipes en tête de ligne.** Une mise en forme unique des
  `@synth` : un maillon par ligne, `|>` au début.
- [x] **E4.5 — Les exports en pipes.** Quand le graphe d'un candidat est
  une chaîne, l'explorateur l'écrit en pipes, pas en `n1 = ugen(…)`.
- [x] **E4.6 — `gcc` / `gc`.** Commenter, décommenter. Sur un maillon :
  le court-circuiter.

Notes de réalisation (2026-11-18) :
- E4.4 / E4.5 : une chaîne multipliée s'écrit `… |> amp(k)`, donc les exports
  sont des chaînes plates, un maillon par ligne. `:format` met en forme le son
  ouvert (pipes en tête, nombres courts) sans le relire. La passe sur les
  fichiers existants de `plugins/user-synths` n'a **pas** été faite : réécrire
  en masse les fichiers du joueur n'est pas un geste à faire sans lui.
- E4.6 a révélé que le DSL et les blocs de patterns recollaient les lignes
  `|>` sans voir les commentaires : un commentaire de fin de ligne avalait le
  maillon suivant, un maillon commenté coupait la chaîne. Corrigé des deux côtés.

Tests : le corpus (`test/fixtures/synths`) passe l'aller-retour après mise
en forme, à SC égal ; `gcc` sur chaque maillon d'un son laisse un son valide.

## Étape 5 — L'atelier

- [ ] **E5.1 — Le son dans le volet.** `gs` sur un nom de son ouvre son
  texte à droite ; l'onde en dessous. Plus de studio, plus de knobs en liste.
  `pane_waveform.jl` (mode sculpt), `modal_sculpt.jl`, `app_sculpt.jl`,
  `wave_sculpt.jl` : ce qui sert à l'atelier est repris, le reste supprimé.
- [ ] **E5.2 — La réglette.** Sous le nombre : nom de l'argument, bornes
  (catalogue d'UGens), « en direct » ou « à la prochaine note ».
- [ ] **E5.3 — En direct.** Le temps du réglage, le littéral devient un
  argument d'un jumeau du son (extension du jumeau `_drone`) : une note
  tenue bouge sans être coupée.
- [ ] **E5.4 — L'objet texte `m`.** `im` / `am`, donc `dam`, `cim`, `yam`,
  `.`. Marche aussi dans une ligne de pattern.
- [ ] **E5.5 — La complétion qui s'entend.** Sur `o`, `O` et `cim` : les
  maillons qui ont un sens à cet endroit, chacun joué à la place ⚑ E0.1.
  `Entrée` garde, `Échap` rend. Un seul `u` annule.
- [ ] **E5.6 — `&`.** Faire bouger (écrit une ligne nommée au-dessus), en
  faire un argument, écouter seul, bifurquer, expliquer.
- [ ] **E5.7 — L'explorateur sur un slot.** `gx` : les candidats se jouent
  dans le pattern, à la place du son du slot. Cartes décrites en mots ;
  réglages derrière `g`.

Tests : chaque geste sur trois sons du corpus (chaîne simple, deux voix,
réinjection) ; le texte reste valide et le son rendu change comme attendu.

Limite acceptée : un signal lu deux fois reste recopié (point F5 de la
roadmap, `shared`). L'atelier ne propose pas d'insérer là où il dédoublerait
un bruit.

## Étape 6 — Hors grille

- [ ] **E6.1 — `Entrée` : maintenant.** Le cycle 0 du slot commence à la
  frappe. État « hors grille » ; `e` recale.
- [ ] **E6.2 — `frappes(instants...; cycles)`.** Un pattern d'instants
  exacts, avec sa fiche.
- [ ] **E6.3 — La boucle.** `Espace o` ouvre, on joue, `Espace o` ferme :
  la ligne `frappes(…)` est écrite et rejoue, calée sur l'instant
  d'ouverture. Longueur libre.

Tests : phase d'un slot lancé à un instant donné ; boucle enregistrée avec
une horloge injectée, instants rendus à l'identique.

## Étape 7 — Le casque

- [ ] **E7.1 — Découvrir les sorties.** PipeWire (`pw-dump`), une modale de
  réglage, rafraîchissement.
- [ ] **E7.2 — Le routage.** Sortie principale et casque ; le casque reçoit
  la sortie principale.
- [ ] **E7.3 — Le delta.** Le son en atelier joue deux fois : l'ancien vers
  la sortie, le nouveau vers le casque. `Entrée` bascule.
- [ ] **E7.4 — L'enregistrement** ne prend que la sortie principale.

Demande SuperCollider et du matériel : tests hors suite par défaut.

---

## Ce qui disparaît

Les trois workspaces et leurs commandes ; la pane MODULATION ; le studio et
ses knobs en liste ; la modale sculpt ; l'édition de `.scd` ; cinq entrées
de bibliothèque fondues en une ; le buffer d'accueil commenté.

## Ce qui n'est pas dans ce plan

- Le noyau de vocabulaire « épinglé à la main » (décision F) : E4.3 compte
  l'usage, l'épinglage attend de voir si le classement suffit.
- `shared(x)` (F5), MIDI natif (F4), pages de wiki des plugins (F2).
- Compenser le délai de 50 ms du slot lancé à la frappe.
