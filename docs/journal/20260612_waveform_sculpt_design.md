# Sous-projet — Sculpter l'onde (manipulation des paramètres dans la vue d'onde)

**Date :** 2026-06-12
**Statut :** design en revue
**Dépend de :** viewer d'onde NRT (`pane_waveform.jl`), explainer (`synth_explainer.jl`),
analyse NRT (`nrt_analysis.jl`), audition live (`synth_audition.jl`).

## But

Manipuler un synthé **directement dans la vue d'onde**, comme un sound designer : on
saisit ce qui **produit** le son (les constantes du graphe + les controls globaux), on
tire dessus, l'onde **se re-render en direct** (~0.34 s à chaud, mesuré), et on l'**écoute
à la demande**. Le synthé reste vivant — on rejoue le génome, on n'édite pas un
enregistrement figé.

C'est la suite naturelle de l'explainer : *explore les composants → tire dessus → vois
(et entends) l'onde changer*. Là où l'explainer **décrit**, le sculpt **agit**.

## Décisions de cadrage

| Sujet | Décision | Raison |
|---|---|---|
| Quoi de manipulable | **Tout `ConstArg` du graphe** (via `_const_slots`) **+ les controls globaux** (`freq`, `sustain`, `gain`, `release`). Univers plat, exhaustif. | « Travailler au niveau de l'onde » : tout ce qui façonne le son est saisissable, sans présélection. |
| Retour visuel | **Onde re-rendue à chaque ajustement**, en NRT, **asynchrone + temporisé** (coalescé). | 0.34 s/render à chaud → sensation live sans geler la TUI (le rendu bloque, donc il part en tâche de fond). |
| Retour audio | **À la demande seulement** (`⏎`), via l'audition live qui **existe déjà** (`audition_hold!`/`audition_play!`). | Respecte le « surtout pas la jouer » par défaut, tout en laissant écouter quand on veut. |
| Disposition | **Colonne vertébrale stable** : knobs posés le long du flux du signal (`_topo_order`, matière→sortie). Les positions ne dépendent **que de la structure**. | C'est ce qui rend l'outil *manipulable* : un knob ne se déplace jamais pendant qu'on tourne des valeurs. |
| Groupement | **Quartiers mous, non supervisés** : clustering par seuil (style `cluster_descriptors`) sur une distance **mixte graphe × acoustique**. Pas d'arbre, pas de frontière dure. | « Grouper un peu sans hiérarchie dure » ; émerge du graphe puis de la réalité sonore. |
| Vivacité | Les quartiers **se reforment** au fil de la sculpture : chaque render apprend la **signature acoustique** de chaque knob ; le re-clustering ne **re-colore** que — **jamais ne déplace**. | « Ça se reforme, mais ça reste manipulable » : on sépare le squelette stable (positions) de la teinte vivante (couleurs). |
| Testabilité | Cœur (`wave_sculpt.jl`) **pur, testé hors-ligne** (vecteurs/samples injectés) ; rendu NRT réel en intégration gardée (`RESSAC_NRT_TESTS`) ; workflows TUI testés via `Tachikoma.update!` avec render mocké. | Même contrat que le reste ; suite par défaut **rapide**. |

## Invariant d'interaction (non négociable)

> **La reformation des quartiers ne déplace jamais un knob.**

Les **positions** dépendent uniquement de la structure du graphe → elles ne bougent pas
quand on édite des valeurs. Les **quartiers** (couleur + vivacité) peuvent respirer, mais
ils ne font que **re-colorer**. Le re-clustering est **temporisé** (au repos, pas à chaque
frappe). Résultat : la bande est un établi stable ; seules les couleurs vivent.

## Modèle de knob

Un **knob** = un nombre réglable à un endroit du génome :

- **Knobs de nœud** : chaque `ConstArg`, repéré par `(node_id, arg_index)` via
  `_const_slots(g)` (`genome_operators.jl:38`). Le slot correspondant
  (`ugen_spec(node.ugen).slots[arg_index]`, positionnel — `genome_render.jl:73`) donne un
  `SlotSpec{name, kind, default, lo, hi, choices}` (`genome.jl:48`), `kind ∈ {:signal,
  :scalar, :choice, :audio}`. **Les knobs viennent UNIQUEMENT des `ConstArg`** → un slot
  qui porte une **connexion** (un `NodeRef`, typiquement les slots `:audio`/`:signal`
  modulés) n'est jamais un knob : il est exclu d'office.
- **Knobs globaux** : les controls de `CONTROL_EDIT_ORDER` (`:freq`, `:sustain`, `:gain`,
  `:release` — `genome.jl:31` ; `:release` est éditable même s'il n'est pas dans le
  constant `CONTROL_NAMES`). Ils n'ont **pas** de `SlotSpec` → leurs ranges sont **définis
  explicitement** (mêmes bornes/échelles que l'éditeur de params de l'explorer,
  `pane_synth_explorer.jl:843` : `freq` log 20–8000, `sustain` 0.01–6, `gain` 0–1,
  `release` 0.01–4). Posés en tête de bande (« global »).

**Range & sensibilité** (touche `h`/`l` = tirer ↓/↑) :

- Bornes = `SlotSpec.lo`/`hi` (ou bornes du control). Pas/step = fraction de `(hi-lo)`.
- **Échelle log inférée du nom** : slot dont le nom contient `freq`/`cutoff` → pas
  multiplicatif (octaves) ; sinon linéaire. (`SlotSpec` n'a pas de marqueur log explicite
  — on infère, cf. gotcha args-catalog.)
- **Repli robuste** : si `arg_index > length(spec.slots)` (arité non garantie au niveau
  génome — cf. gotcha `repair!`), pas de crash : balayage **log relatif** autour de la
  valeur courante (×/÷). Jamais d'indexation hors-bornes de `spec.slots`.
- `:choice` → on cycle parmi `choices` au lieu d'un balayage continu.

**Édition** : tirer un knob mute la valeur (`ConstArg.value` ou `g.controls[name]`) dans
la **copie de génome que possède le pane**. C'est cette copie qu'on exporte/relance.

## La colonne vertébrale (disposition stable)

Bande 1D, knobs ordonnés par **flux du signal** : `_topo_order(g)`
(`genome_render.jl:202`). **Vérifié** : c'est un DFS post-ordre depuis la sortie qui
empile **les entrées avant le nœud** → la liste va `[source … sortie]`, donc **déjà
matière → sortie** (pas de `reverse`). On lit la bande **matière → sortie**, exactement le
sens de l'explainer (« À LA BASE » … « EN SORTIE »).
Les globaux ouvrent la bande. Un knob occupe une cellule ; le focus (`j`/`k`) glisse le
long de la bande. Comme l'ordre ne dépend que de la structure, **il ne change pas** tant
qu'on n'édite que des valeurs.

## Quartiers mous (la teinte vivante)

**Signal de proximité** entre deux knobs = mélange de deux distances :

1. **Graphe** (prior, immédiat) : distance en *hops* entre leurs nœuds dans le DAG.
   On construit une **adjacence non orientée** une fois par structure (les `NodeRef` de
   `node.args` donnent les arêtes entrantes ; les sortantes par un scan — pas d'index
   inverse caché, cf. gotcha) ; BFS → distance nœud-à-nœud. Deux knobs du **même nœud**
   (ex. `cutoff`/`rq` d'un `RLPF`) sont à distance 0.
2. **Acoustique** (apprise, vivante) : la **signature** de chaque knob — *ce qu'il déplace
   dans le son*. À chaque render terminé où **un seul knob** a changé depuis le render
   précédent, on calcule `Δdescripteurs` (cf. plus bas) et on l'attribue à ce knob
   (moyenne mobile de la **direction** du déplacement, normalisée). Distance acoustique =
   `1 − cos(signature_i, signature_j)`.

**Distance mixte** : `d = (1-α)·d_graphe + α·d_acoustique`, où `α` monte de 0 vers ~0.7 à
mesure que les signatures se remplissent. Au démarrage : pur graphe (stable, lisible) ;
en explorant : migre vers la réalité sonore (les knobs qui *sonnent* pareil se
rapprochent, même s'ils sont loin dans le graphe).

**Clustering** : seuil glouton, **style `cluster_descriptors`** (`ga_targeting.jl:57`) —
on parcourt les knobs, on rattache au quartier le plus proche, sinon on en ouvre un.
**Seuil large** → peu de **grands** quartiers (côté source, côté filtre, côté espace…),
pas une poussière de micro-groupes.

**Rendu mou** : chaque knob porte `(quartier_id → couleur, force_d'appartenance →
vivacité)`. La force = à quel point le knob est au cœur de son quartier (proche du médoïde
vs proche du quartier voisin). Les knobs de **bordure** sont **ternes et bavent** entre
deux teintes. **Aucune boîte, aucun label-vérité, aucun arbre.**

**Reformation** : re-clustering **temporisé** (déclenché au repos après une rafale
d'édits, pas par frappe). Recolore uniquement → respecte l'invariant d'interaction.

### Descripteurs dérivés des samples (gratuits, côté Julia)

On ne refait **pas** d'appel sclang pour les descripteurs : on les dérive des **samples
déjà rendus** pour l'onde, dans Julia, par des **proxies temps-domaine bon marché** (pas
de nouvelle dépendance FFT) :

- **brillance** ≈ taux de passage par zéro (ZCR) ;
- **graves** ≈ ratio d'énergie après lissage passe-bas simple ;
- **bruité** ≈ variabilité locale / irrégularité du signal ;
- **attaque** & **sustain** ≈ forme de l'enveloppe RMS (montée, plateau) ;
- **hauteur** ≈ netteté de l'auto-corrélation au lag dominant.

Vecteur ~6 dims, parallèle conceptuel aux `DESCRIPTORS` SC mais calculé hors-ligne. Pour
les **signatures** seul le *sens du changement* compte → ces proxies suffisent. (Si on
veut un jour plus de fidélité, on branche `analyze_genomes` — découplé.)

## Boucle de feedback

```
tirer un knob (h/l)  ──►  mute la valeur dans la copie de génome
        │                         │
        │                         ▼
        │             marque « render demandé » (version N)
        ▼                         │
  affichage immédiat              ▼   (tâche de fond, bornée, coalescée)
  (valeur, bande)        render_genome_audio(copie)  ~0.34 s
                                  │
                                  ▼
                 swap des samples + proxies descripteurs
                                  │
                    ┌─────────────┴──────────────┐
                    ▼                              ▼
        onde redessinée (frame suivante)   si 1 seul knob changé :
                                            MAJ signature du knob
                                                  │
                                                  ▼
                                    (au repos) re-clustering → re-teinte

⏎  ──►  audition_hold!(copie) sur le serveur SC live (si scheduler tourne)
```

**Asynchronie** : `render_genome_audio` **bloque la tâche entière** (appel `sclang` via
`Base.run`). L'app tourne **`-t auto`** (multi-thread — exigé par le justfile/README, et
`Threads.@spawn` est déjà utilisé : `tui_scope.jl:194`, `io_scheduler.jl:479`,
`tui_app.jl:4874`). Donc le render part en **`Threads.@spawn`** sur un thread worker → le
thread principal (boucle TUI) **n'est pas gelé**. Handoff **thread-safe** : slot de
résultat sous verrou + compteur de **génération**. **Coalescing borné** : au plus **un
render en vol** ; à chaque tir on incrémente `version_demandée` ; quand un render finit, on
ne garde son résultat que s'il est encore le plus récent, et on relance si
`version_demandée > version_rendue`. Converge toujours vers le dernier état, file bornée
(cf. mémoire *bounded-wait-loops*). **Nettoyage** : `on_close!` pose un drapeau « fermé »
→ un résultat tardif est jeté.

## Interaction (touches, dans la vue d'onde)

| Touche | Action |
|---|---|
| `s` | bascule mode **sculpt** ↔ **vue** (libre : `s` n'a aucun binding global en `:normal`) |
| `j`/`k` | déplace le focus knob le long de la bande ; **clampe aux bords** (pas de wrap) |
| `Tab` / `⇧Tab` | saute au **voisin de graphe** avant/arrière (de proche en proche) |
| `h`/`l` (ou `◀`/`▶`) | **contextuel** : en **sculpt**, *tire* le knob ↓/↑ (re-render temporisé) ; en **vue**, *défile* l'onde (comportement actuel) |
| `H`/`L` | en sculpt : défile l'onde (le pan reste accessible sans quitter sculpt) |
| `⏎` | **joue** le son courant sur le serveur live (hors modaux Piano/Tap/Pane) |
| `0`, molette, `+`/`-` | inchangés dans les deux modes : reset / zoom-vers-pointeur / zoom |
| `e` | exporte le génome sculpté (chemin d'export existant, génome embarqué) |

La bande de knobs occupe quelques lignes ; l'onde garde l'essentiel du pane.

**Conflits de routage résolus (revue adversariale) :**

- **`h`/`l` contextuels** : aujourd'hui `h`/`l` défilent l'onde (`pane_waveform.jl:110`).
  En sculpt ils *tirent* le knob (c'est ce que montraient tes maquettes : `◀──●──▶`) ; le
  pan reste accessible en sculpt via `H`/`L` et la molette. En mode vue, `h`/`l` défilent
  comme avant. Aucune capacité perdue.
- **`Tab` intercepté globalement** (`tui_app.jl:1402` : swap de focus patterns↔synth quand
  un pane synth est ouvert) → on **ajoute une garde** pour laisser passer `Tab` quand le
  pane focalisé est un `WaveformPane` en sculpt. `⇧Tab` (`:backtab`) n'est **pas**
  intercepté → déjà libre.
- **`⏎`** atteint le pane focalisé hors modal (Piano/Tap/Pane l'overrident) — à confirmer
  par un test ; sinon route explicite comme `Tab`.
- **`e`** : l'intercept patterns (`tui_app.jl:1549`) est gardé sur `role === :patterns` →
  quand le pane d'onde a le focus, `e` lui parvient (mutuellement exclusif, comme le `e`
  d'export de l'explorer).

## Points d'entrée

- **Depuis l'explorer** : une touche ouvre le candidat focalisé (ou un composant solo) en
  **mode sculpt**, via le seam `_EXPLORER_WAVEFORM_REQUEST`
  (`pane_synth_explorer.jl:16`, drainé `tui_app.jl:547`) **étendu d'un drapeau `sculpt`**
  (ou un seam jumeau `_EXPLORER_SCULPT_REQUEST`). Réutilise `_explorer_waveform_component!`
  pour le solo.
- **Depuis `:synth`** : ouvrir un synthé **exporté** (ex. `metalressone`) en sculpt — on
  récupère le génome par `genome_from_text` (commentaire embarqué) ou `genome_from_dsl`
  (DSL nu), **machinerie déjà écrite** pour l'explainer (`explain_synth_file`). Commande
  type `:sculpt <nom>` symétrique de `:explain`.

## Persistance

`serialize`/`deserialize` du pane : **génome** (round-trip via `serialize_genome`) +
**état sculpt** minimal (mode, focus, fenêtre de vue). Les signatures accumulées sont
**optionnellement** persistées (sinon elles repartent du prior graphe — acceptable).
L'**export** écrit le génome édité (les `ConstArg`/controls tirés sont déjà dans la copie).

## Gestion d'erreurs

- **Pas de `sclang`** (`_sclang_available()` faux) : pas de mise à jour d'onde ; on garde
  le dernier tracé + une note ; **les édits mutent quand même le génome** (on sculpte à
  l'aveugle, on exporte). Pas de crash.
- **Pas de scheduler live** (`_LIVE_SCHEDULER[]` nul) : `⏎` est un **no-op** avec un
  indice ; le reste marche.
- **Slot hors-bornes / arité** : repli balayage relatif, jamais d'indexation illégale.
- **Render échoué** : on conserve les samples précédents ; on retente au prochain édit.

## Découpage en modules

- **`src/wave_sculpt.jl`** (nouveau, **logique pure, sans TUI**) :
  `Knob`, `enumerate_knobs(g)`, `knob_range`/`knob_step` (inférence log + repli),
  `spine_order(g)`, `build_adjacency(g)` + `hop_distance`, `descriptors_from_samples`,
  `KnobSignature` + `update_signature!`, `soft_quartiers(knobs, dgraph, signatures; α)`
  (clustering seuil + force d'appartenance). **Tout testable hors-ligne.**
- **`src/pane_waveform.jl`** (modif) : champs sculpt (`sculpt::Bool`, `knobs`, `focus`,
  `quartiers`, `signatures`, handoff render async, `last_descriptors`,
  `pending_version`), touches, rendu de la bande de knobs (teinte quartier + barre du knob
  focalisé), déclenchement/coalescing du render de fond, `on_close!` (nettoyage tâche).
- **`src/pane_synth_explorer.jl`** (modif) : entrée « ouvrir en sculpt » (candidat /
  composant solo).
- **`src/tui_app.jl`** (modif) : drain du seam sculpt ; commande `:sculpt <nom>`.
- **`src/Ressac.jl`** (modif) : `include("wave_sculpt.jl")` + ajout au `@compile_workload`.
- **Tests** : `test/test_wave_sculpt.jl` (nouveau) ; extensions de
  `test/test_pane_waveform.jl` et `test/test_ui_integration.jl`. Render mocké via un seam
  `Ref` (façon `_EXPLORER_ANALYZE`) pour garder la suite par défaut rapide ; intégration
  NRT réelle gardée derrière `RESSAC_NRT_TESTS`.

## Ordre de livraison (incréments testables)

Chaque incrément laisse le viewer d'onde **fonctionnel** ; le sculpt est **opt-in** (`s`).

1. **Cœur knobs** (`wave_sculpt.jl`) : `enumerate_knobs` + ranges (inférence log + repli) +
   `spine_order`. Tests purs.
2. **Proximité graphe** : `build_adjacency` + `hop_distance` + `soft_quartiers` (graphe
   seul, α=0). Tests purs.
3. **Souffle acoustique** : `descriptors_from_samples` + signatures + quartiers mixtes
   (α montant). Tests purs (samples injectés).
4. **Mode sculpt dans le pane** : rendu bande + teinte + focus + navigation (`j`/`k`/`Tab`)
   + tir (`h`/`l`) mutant `ConstArg`/control. Render **mocké**. Tests d'intégration TUI
   (`Tachikoma.update!`).
5. **Render NRT async** : tâche de fond bornée + coalescée + handoff → onde mise à jour +
   alimente les signatures. Test d'intégration gardé (`RESSAC_NRT_TESTS`).
6. **Audio à la demande** (`⏎`) via le chemin d'audition existant.
7. **Points d'entrée** : explorer → sculpt ; `:sculpt <nom>` pour un synthé exporté. Tests
   TUI.
8. **Persistance** (serialize/deserialize état sculpt) + export du génome édité + ajout au
   `@compile_workload`.

## Vérifications faites (revue adversariale)

- **Threads** : app lancée `-t auto` (justfile/README, « required ») → `Threads.@spawn`
  pour le render ne gèle pas l'UI. ✅
- **`_topo_order`** : sources→sortie confirmé (post-ordre, entrées d'abord). Pas de
  `reverse`. ✅
- **Routage clavier** : `h`/`l`, `Tab`, `⏎`, `s`, `e` cartographiés ; correctifs ci-dessus.
- **APIs** : `_const_slots`, `SlotSpec`, `g.controls`/`CONTROL_EDIT_ORDER`,
  `audition_hold!`/`audition_play!`, `render_genome_audio`, `cluster_descriptors`,
  `serialize_genome`/`deserialize_genome`, `genome_from_text`/`genome_from_dsl` — tous
  vérifiés présents avec les signatures attendues.

## Risques

- **Handoff async** : la tâche de fond + le slot sous verrou + le compteur de génération
  doivent être propres (pas de zombie, bornés, nettoyés à `on_close!`). Isolé dans le pane.
- **Proxies descripteurs temps-domaine** : moins fidèles que les descripteurs SC ; suffisant
  pour la *direction* des signatures, mais à surveiller. Branchement `analyze_genomes`
  possible en repli si le clustering acoustique déçoit.
- **Lisibilité de la teinte en terminal** : palette limitée → la « vivacité » (force
  d'appartenance) doit rester perceptible. À caler à l'implémentation.
