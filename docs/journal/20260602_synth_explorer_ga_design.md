# Sous-projet — Explorateur de synths par algorithme génétique interactif (IGA)

**Date :** 2026-06-02
**Statut :** design validé, prêt pour le plan d'implémentation

## But

Un utilitaire d'exploration de synthétiseurs piloté par un algorithme génétique
**interactif** : à chaque génération, une grille de 6 à 9 candidats qui divergent
(en structure ET en valeurs) ; l'utilisateur favorise / dévalue à l'oreille, et la
génération suivante reproduit/croise/mute les favoris. On explore *par sélection*
plutôt que par savoir-faire — pertinent quand on ne maîtrise pas assez le domaine
synthèse pour tweaker à la main.

## Décisions de cadrage (issues du brainstorming)

| Sujet | Décision | Raison |
|---|---|---|
| Liberté structurelle | **A — graphe de signal libre** (DAG d'UGens quelconque) | Exploration structurelle maximale ; le prix (validité/sécurité) est traité comme composant central. |
| Source du génome | **A3 — archétypes-graines natifs + export**, architecturé pour **A2** (parser DSL→DAG) plus tard | Évite d'écrire le parser DSL→graphe maintenant ; les graines garantissent une gén 0 audible. |
| Audition | **Compile background priorisée, non bloquante** + clic-pour-jouer + drone/hold + mini-clavier | SC compile de toute façon en asynchrone ; l'UI ne bloque jamais. |
| Sélection | **(2) Pool de reproduction avec croisement**, modèle de données prêt pour **(3)** population pondérée | Le croisement de sous-graphes brille sur DAG libre ; mono-favori = divergence simple. |
| Sortie / commit | **C — les trois** : sauver comme graine (principal), sauver vers `user-synths`, exporter vers éditeur | Le workflow dominant est de promouvoir les bons sons en nouvelles graines. |
| Contrat I/O | Interface fixe : `:freq`/`:sustain`/`:gain` **existent** comme entrées + **une** sortie sécurisée ; mais l'usage interne de `:freq` est **libre** (×ratio, FM, détune…) | Tout candidat est un instrument jouable/exportable ; `:freq` reste un point de greffe riche, pas un câble figé. |
| Audition hauteur | **Mini-clavier** (écouter chaque candidat à différentes hauteurs) | La structure répond différemment selon la note d'entrée. |

## Architecture & découpage en modules

Au centre : le **génome** comme type de donnée pur (un DAG). Autour : des modules
qui le produisent, le transforment, le rendent et le jouent. Toute la logique
difficile (génome, validité, mutation, croisement, GA) est **testable sans son ni
terminal**.

```
                  ┌─────────────────┐
   archétypes ───▶│                 │
   (graines) ────▶│   GenomeSource  │──┐
   [futur: A2     │                 │  │
    parser DSL]   └─────────────────┘  │
                                       ▼
   ┌──────────────┐            ┌──────────────┐         ┌──────────────┐
   │  Operators   │◀──────────▶│    Genome     │────────▶│   Renderer    │
   │ mutate/cross │   (DAG de   │  (DAG typé +  │ genome  │ genome → Sig  │
   └──────────────┘   noeuds)   │  contrat I/O) │  →DSL   │  → DSL string │
                                └──────────────┘         └──────┬───────┘
   ┌──────────────┐            ┌──────────────┐                │
   │   GA Engine  │───────────▶│  Population   │                ▼
   │select→nextgen│  poids/    │ (candidats +  │         ┌──────────────┐
   │ (breeding 2, │  notes      │  poids/notes) │         │  Audition     │
   │  prêt p/ 3)  │            └──────────────┘         │ file compile  │
   └──────────────┘                                      │ bg + jeu SC   │
                                                         └──────────────┘
            ▲                                                    ▲
            │                  ┌──────────────┐                  │
            └──────────────────│ ExplorerPane  │──────────────────┘
                               │ (PaneImpl)    │
                               └──────────────┘
```

### Modules (un fichier, une responsabilité)

1. **`genome.jl`** — le type `Genome` (DAG de nœuds UGen typés), le **catalogue
   `UGenSpec`**, le contrat I/O, les invariants, la sérialisation native. Aucune
   dépendance SC/UI.
2. **`genome_render.jl`** — `Genome → Sig` (DSL string) via l'étage de sécurité.
   Pure transformation.
3. **`genome_validity.jl`** — vérif/réparation : rates, arités, sortie unique,
   pas de cycle non-différé.
4. **`genome_archetypes.jl`** — la `GenomeSource` : biblio de graines natives +
   chargement des graines utilisateur. Le futur parser DSL→DAG (A2) sera **une
   autre `GenomeSource`** branchée ici, sans rien changer en aval.
5. **`genome_operators.jl`** — mutation paramétrique + structurelle + croisement.
6. **`ga_engine.jl`** — `Population` (génomes + poids), `select→next_gen`, rayon
   de divergence. Découplé de l'UI.
7. **`synth_audition.jl`** — file de compile background priorisée, noms SynthDef
   bornés, jeu via SC, mini-clavier, drone.
8. **`pane_synth_explorer.jl`** — le `PaneImpl` : grille, interactions, commit,
   modal détails. Orchestre seulement ; aucune logique GA/génome.

**Frontières clés :** `Genome` ne connaît ni SC ni l'UI. Opérateurs + moteur GA ne
connaissent que `Genome`. Seuls audition et pane touchent SC/Tachikoma.

## Le modèle Génome

**Un nœud** = `{id, ugen::Symbol, rate::Symbol, args::Vector{Arg}}`, où chaque
`Arg` est une **constante** (numérique), une **référence de nœud** (edge du DAG),
ou une **référence de contrôle** (`:freq`/`:sustain`/`:gain`).
**Un `Genome`** = `{nodes, output_id, controls}`. DAG sérialisable en pur Julia.

**Catalogue `UGenSpec` (clé de voûte).** Pour chaque UGen : rates autorisés
(`:ar`/`:kr`/`:ir`), et la liste de ses slots d'argument (nom, *type* du slot —
signal / scalaire / choix énuméré, défaut, plage ou choix). Rend la mutation
type-safe et le rendu correct. Dérivé du vocabulaire d'UGens déjà présent dans
`synth_dsl.jl`, et extensible : ajouter un UGen au catalogue l'expose à la mutation
sans toucher aux opérateurs.

**Modèle de rates + coercition.** Edges respectent la compatibilité (`:ir`→tout,
`:kr`→`:ar` OK, `:ar`→slot `:kr` réparé). La mutation a le droit de produire des
incohérences ; `genome_validity.jl` **répare** (re-rate ou insère une conversion)
plutôt que de rejeter, pour ne pas gâcher des candidats.

**Contrat I/O.** Les trois nœuds de contrôle existent toujours et sont routables
librement ; exactement un nœud terminal est la sortie. *Comment* le DAG utilise
`:freq` est libre (×ratio, FM, détune `[:freq, :freq*1.01]`, sub-osc `:freq/2`,
fréquence de modulation…).

**Étage de sécurité (au rendu).** `genome_render.jl` enveloppe systématiquement la
sortie : garde anti-NaN/Inf (`Sanitize`/`CheckBadValues`), `LeakDC`, `Limiter`,
normalisation de gain. Aucun candidat ne peut saturer ni crever les oreilles.

**Sérialisation native.** `nodes + edges + output` → Dict → disque et retour. Sauver
une graine et la re-muter ne demande **aucun** parser A2.

**Invariant de discipline :** la mutation ne valide jamais elle-même — elle mute
librement, puis la validité normalise. Toute la logique « rester rendu-able » est
concentrée en un seul endroit testable.

## Opérateurs de mutation & croisement

Fonctions **pures** `Genome → Genome` (ou `(Genome,Genome) → Genome`), suivies de
la normalisation validité. Paramétrique et structurel partagent le catalogue
UGenSpec — conçus ensemble.

**Paramétriques** (topologie inchangée) :
- *Perturber une constante* : jitter gaussien sur un slot, échelonné par la plage ×
  le rayon de divergence.
- *Basculer un choix énuméré* (courbe d'enveloppe, interpolation…).
- *Changer le rate* d'un nœud (parmi ceux autorisés).

**Structurels** (topologie modifiée) :
- *Insérer* : splicer un nouvel UGen sur une edge (ex. envelopper un signal dans un
  filtre).
- *Retirer* : bypasser un nœud (relier son entrée à ses consommateurs) et le
  supprimer.
- *Swap UGen* : remplacer le type d'un nœud par un compatible du catalogue.
- *Recâbler une edge* : repointer un arg vers un autre nœud existant.
- *Greffer une modulation* : brancher la sortie d'un nœud (ex. LFO) sur un slot
  jusque-là constant → paramètre statique devient modulé.
- *Feedback* : router un nœud aval vers un arg amont **via un nœud de délai inséré**
  (seule façon contrôlée d'obtenir un cycle ; la validité garantit le délai).

**Croisement** (deux parents → enfant) : *swap de sous-graphe*. On prend un sous-DAG
enraciné sur un nœud du parent A et un point d'insertion compatible (par rate/rôle)
dans le parent B, et on splice. Gère le remapping d'ids, les refs de contrôle
pendantes (résolues vers les nœuds de contrôle de l'enfant), puis réparation
validité.

**Rayon de divergence** (un seul bouton utilisateur) pilote : (a) nombre/probabilité
d'opérateurs par enfant, (b) magnitude du jitter paramétrique, (c) ratio
structurel/paramétrique. À fond = mutations sauvages ; bas = micro-ajustements.

Le nœud `:freq` (et les autres contrôles) sont des points de greffe naturels.

## Moteur GA & boucle de sélection

**`Population`** = candidats courants (chacun un `Genome`) + un registre de
**poids/notes** qui vit *à travers* les générations. Favoriser/dévaluer écrit dans
ce registre — pas dans un simple set « parents du tour ». Ce découplage permet de
brancher (3) plus tard en ne changeant que `select→next_gen`.

**Génération 0.** Choisir une graine (archétype) ; ses mutations remplissent la
grille. Tout est déjà audible (graines saines + étage de sécurité).

**Boucle.** Afficher → favoriser (plusieurs) / dévaluer (plusieurs) →
`select→next_gen` → recommencer.

**`select→next_gen` (breeding pool, modèle 2) :**
- **Élitisme** : les N meilleurs favoris passent tels quels (1-2 slots réservés).
- **Croisement** : des paires de favoris croisées remplissent une part des slots.
- **Mutation** : des favoris mutés au rayon courant pour le reste.
- **Mono-favori** → dégénère en « diverge du champion ».
- **Dévalués** : exclus du pool de parents, leurs sous-graphes distinctifs
  sous-pondérés dans les greffes (signal négatif léger).

**Taille de génération** : 9 par défaut (grille 3×3), configurable à 6. Au moins 1
slot d'élitisme.

**Cas limites :** aucun favori → bouton « regénère » (nouveau jeu depuis la base) ;
tout dévalué → élargir le rayon de divergence.

**Repro/test** : RNG seedable injectée → les tests fixent la graine et assertent
exactement la génération produite. Moteur pur.

## Audition

Chemins OSC existants : `/dirt/evalSC` (définit un SynthDef **sans le jouer**),
`/ressac/play <nom> [args]` (instancie un SynthDef déjà défini),
`_LIVE_SCHEDULER[].osc` pour émettre depuis le pane.

**File de compile priorisée, non bloquante.** À la naissance d'une génération :
rendre chaque candidat (génome→DSL→source) et enfiler les définitions dans l'ordre
des cases. Un worker draine la file, envoie les `/dirt/evalSC` espacés (pas de flood
SC). État par case : `en file → défini → prêt`. L'UI ne bloque jamais.

**Sémantique de « prêt » (SC ne renvoie pas d'accusé de compilation).** Comme
`/dirt/evalSC` est fire-and-forget, on marque une case `prêt` de façon optimiste
après l'envoi de sa définition + un court délai de garde (le temps de compilation
SynthDef est de l'ordre de quelques ms). Le chemin de jeu est rendu **robuste à une
def pas encore prête** : le *premier* jeu d'une case dans une génération passe par
`/ressac/evalAndPlay` (définit + joue atomiquement, paye la latence une fois) ; les
jeux suivants passent par `/ressac/play <nom>` (instantané). Ainsi un clic ne peut
jamais tomber sur un SynthDef inexistant, et l'optimisme sur l'état `prêt` n'est
qu'indicatif.

**Pas de fuite de SynthDef.** Noms = pool **borné indexé par case** :
`ga_slot1 … ga_slot9`. Chaque génération **redéfinit** ces mêmes noms → SC n'accumule
jamais plus de 9 SynthDefs ; « libérer la génération abandonnée » = la redéfinir au
tour suivant.

**Clic = jouer.** Prête → `/ressac/play ga_slotN [\freq, f, \sustain, s]`,
quasi-instantané. Pas prête → saute en tête de file ; joue dès défini.

**Mini-clavier.** Rangée de touches dans le pane ; appuyer une note envoie le `:freq`
correspondant comme arg de jeu → entendre le candidat focalisé à différentes hauteurs.

**Drone/hold (toggle).** Le candidat tenu est (re)joué en continu. Comme les noms de
slot sont redéfinis à chaque génération, tenir un candidat le **promeut vers un nom
stable dédié** (`ga_held`) défini à part, pour que la génération suivante ne perturbe
pas la voix qui drone. Naviguer en drone libère l'ancienne voix et démarre la nouvelle.

**Nettoyage** (`on_close!` du pane) : libère la voix drone, stoppe la file.

## L'UI du pane

Nouveau `PaneImpl` (kind `:explorer`), ouvrable dans l'arbre workspace
(`:vsplit explorer` ou commande `:explore`). À l'ouverture, un **sélecteur de graine**
(biblio d'archétypes) choisit la base de gén 0.

```
┌ SYNTH EXPLORER · gén 7 · div ███░░ ──────────────┐
│ ┌1 ♥─────┐ ┌2 ──────┐ ┌3 ✗─────┐                │
│ │saw→rlpf │ │2osc FM  │ │noise   │   ← label = résumé│
│ │+lfo  ▸  │ │ ·prêt   │ │ ·compil.│     structurel court│
│ └─────────┘ └─────────┘ └─────────┘   ▸ = en lecture  │
│ ┌4 ──────┐ ┌5 ♥─────┐ ┌6 ──────┐    ♥ favori ✗ déval│
│ │ …       │ │ …       │ │ …       │                  │
│ └─────────┘ └─────────┘ └─────────┘                  │
│ ┌7 ──────┐ ┌8 ──────┐ ┌9 ──────┐                    │
│ │ …       │ │ …       │ │ …       │                  │
│ └─────────┘ └─────────┘ └─────────┘                  │
│ clavier: [z x c v b n m ,]   (mode k)                │
│ n:gén suiv  f:favori d:déval  i:détails  s w e:commit│
└──────────────────────────────────────────────────────┘
```

Chaque case : index/touche, **résumé structurel court** (UGens dominants, nb de
nœuds — pas le DSL complet), état (`compil.`/`prêt`), marqueur (♥/✗), `▸` si en
lecture. Case focalisée surlignée en couleur d'accent (thème par-mode existant).

**Clavier (idiome modal Ressac) :**
- `hjkl`/flèches : focus ; `1`-`9` : saut direct.
- `Espace` : jouer la case focalisée (one-shot) ; `t` : toggle drone/hold.
- `f` : favoriser / `d` : dévaluer (re-presser = annuler).
- `n` : génération suivante ; `R` : regénère sans valider.
- `[` / `]` : rayon de divergence − / +.
- `m` : sous-mode clavier (rangée du bas = notes sur le candidat focalisé) ;
  `Esc` en sort.
- `i` : **modal détails** — DSL complet rendu + stats (nb nœuds, UGens, profondeur),
  lecture seule, scrollable ; commit `s`/`w`/`e` accessibles depuis le modal.

**Souris :** clic case = focus + joue ; clic zone ♥ = favori, zone ✗ = dévalue ;
clic mini-clavier = joue à cette hauteur.

**Commit C :** `s` sauver comme graine (principal), `w` écrire vers
`user-synths/<nom>.jl`, `e` exporter vers un onglet éditeur. `s`/`w` ouvrent une
mini-saisie de nom.

## Persistance

**Graines (durable).** Biblio d'archétypes en **format génome natif sérialisé**
(Dict de `{nodes, edges, output, controls}`), dans un dossier dédié (ex.
`plugins/synth-seeds/`). Les archétypes livrés y sont posés au boot ; `s` y ajoute
les tiens. Boucle vivante : explorer → promouvoir en graine → re-explorer depuis.

**Session d'exploration (reprise).** `serialize(::ExplorerPane)` capture la
`Population` (génomes + poids/notes), le numéro de génération, le rayon de
divergence, la graine RNG. Fermer/rouvrir Ressac reprend l'exploration via le
mécanisme de layout existant ; restauration par le ctor du pane.

## Stratégie de test

Presque tout est pur → testable sans son ni terminal.

- **Génome + validité** : un génome muté/croisé reste valide et **rend-able** ;
  rates cohérents ; sortie unique ; cycles seulement via délai.
- **Opérateurs** : chaque opérateur sur un génome connu (RNG fixe) → assertion sur
  la structure résultante + validité.
- **Render** : génome→DSL contient l'étage de sécurité (LeakDC/Limiter/Sanitize),
  contrôles présents, sortie unique. Round-trip sérialisation identique.
- **Moteur GA** : RNG seedée → `select→next_gen` produit exactement la génération
  attendue ; élitisme préserve les favoris ; mono-favori = divergence ; dévalués
  exclus.
- **Audition** : noms bornés (jamais > 9 SynthDefs) ; clic avant `prêt` → priorité ;
  drone promeut vers `ga_held`. OSC/scheduler mocké (assert les messages émis).
- **Pane (intégration TUI)** : test end-to-end façon `Tachikoma.update!` — ouvrir
  l'explorer, focus/favori/`n`/inspect, vérifier rendu et transitions d'état.

## Hors périmètre (sous-projets futurs)

- **A2 — parser DSL→DAG** : importer un synth DSL écrit à la main dans le génome
  pour le faire muter. L'archi le prévoit (autre `GenomeSource`) mais ce n'est pas
  dans ce sous-projet.
- **(3) — population pondérée persistante** : le modèle de données (poids/notes) est
  prêt ; seul `select→next_gen` changerait.
- **Pré-compilation eager (option 2 d'audition)** : si la latence à la demande gêne.
