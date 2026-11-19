# Roadmap Ressac

Issue de l'audit du 2026-11-16 (moteur, synthèse, TUI, plugins/tests/dépôt)
et de ce qui restait dans l'ancien `TODO.txt`. Une case cochée = corrigé
**et** couvert par un test. « (lecture) » = constat non reproduit à l'audit,
à confirmer avant de corriger.

Ordre : ce qui peut couper le son ou fermer l'app en live d'abord, puis la
justesse du moteur, puis le reste.

## Phase 0 — Filet de sécurité des tests

- [x] T1 — La suite n'écrit plus dans `~/.config/ressac` (`last_layout.toml`, `layouts/`) : racine de config surchargeable, pointée sur un `mktempdir` dans `runtests.jl`.
- [x] T2 — Plus d'écriture relative au `pwd` dans le dépôt (`sessions/<nom>.txt`, `plugins/user-synths/scutest.jl`) : même bac à sable.
- [x] T3 — `test/helpers.jl` unique (`MockOSCClient` ×15, `_new_app`, `_with_test_scheduler`) ; chaque fichier de test tourne seul.
- [x] T4 — `with_clean_registries(f)` : instantané/restauration au lieu des `empty!` + rechargement des vrais plugins.
- [x] T5 — NRT : opt-in sans détection de capacité — `RESSAC_NRT_TESTS=1` sans sclang échoue au lieu de sauter.
- [x] T6 — Les 14 `@test true` remplacés par une assertion sur l'état ou le log.
- [x] T7 — Plus de vrai port ni de `sleep` : `test_vim_motions.jl:7` (57120), `test_plugins.jl:218` (`start_live!` réel), `test_sc_autodiscover.jl:356` (57121), `test_scheduler.jl:311`.
- [x] T8 — Les tests ne ré-incluent plus de fichier source (`pane_editor.jl`, `pane_waveform.jl`, `pane_synth_explorer.jl`) : l'état de référence des registres est restauré entre fichiers.
- [x] T9 — La charge de précompilation tourne en bac à sable : elle écrasait `~/.config/ressac/last_layout.toml` à chaque recompilation (double Échap → `_quit!` → `save_layout`).
- [x] T10 — Plus de réseau dans la suite : `:sc reverb` allait sur sccode.org ; le client HTTP passe par `_SCCODE_GET`, remplacé par un faux dans `helpers.jl`.

## Phase 1 — Ne jamais tomber en live

- [x] L1 — Scheduler : `try/catch` par slot (et par encodage d'événement), le slot fautif est muté et signalé une fois ; le curseur n'avance qu'après (`io_scheduler.jl:479-522`).
- [x] L2 — `set_cps!` ne rejoue plus le lookahead déjà expédié (`io_scheduler.jl:636`).
- [x] L3 — cps fini et borné partout (`:cps`, `cps!`, `/ressac/set`) ; `app_view.jl:465` ne lève plus.
- [x] L4 — Fenêtre de rattrapage bornée après une suspension (plus de rafale de bundles en retard).
- [x] L5 — Course au changement de tempo : `now - t_start` calculé sous le verrou (`io_scheduler.jl:663`) (lecture).
- [x] L6 — Garde-fou sur le chemin souris et sur `view` / chaque `render!` de pane (`app_input.jl:22`, `app_view.jl:287`).
- [x] L7 — `slot()` : garde de ré-entrance, `pattern_get` sous verrou, type d'élément conservé (`mix_helpers.jl:341`).
- [x] L8 — `Pattern{Any}` jouable : `event_to_osc` de repli avec `cps`, `p"0 1" + 1` typé (`io_scheduler.jl:389`, `core_tidal.jl:1105`).
- [x] L9 — `push_played_note!` tolère une note non numérique (`set(:note, :foo)`).
- [x] L10 — NRT sclang avec vrai timeout : `wait = false`, kill sur Timer, script SC qui sort toujours (`nrt_analysis.jl:115`).
- [x] L11 — Registres (synths, instruments, alias) protégés contre la lecture concurrente du scheduler (verrou ou instantané immuable).
- [x] L12 — Autres états partagés entre threads : `push_played_note!`, `_CONTROL_STRUCT`, `_OSC_AD_HOC_HANDLERS`, `_APP_LOG`, historique du spectrogramme ; `start!` sans double démarrage (lecture).
- [x] L13 — `:pause`, `:tap`, `:piano` fonctionnent quel que soit le focus ; `:pause` a toujours une sortie (`app_layers.jl:72-89`).
- [x] L14 — Saisie de texte hors éditeur : `!`, `:`, Ctrl-w ne sont plus interceptés dans une recherche ; filtre acceptant les accents (`tk_picker.jl:44`).

## Phase 2 — Justesse du moteur de patterns

- [x] M1 — Requête de tenue `_held` à côté de la requête d'attaque (un événement est déjà son `whole`) ; les lectures de « valeur active à t » (contrôles, `mask`, arithmétique, `fast` patterné, `chop`, `ply`, `bend`, `rev`) retrouvent l'événement englobant ; le contrat est écrit dans `core_patterns.jl`. Limite connue : un événement de plus de `_HELD_LOOKBACK` (16) cycles passé par un combinateur qui ne transmet pas sa tenue n'est plus vu.
- [x] M2 — `every`, `lastOf`, `sometimesBy`, `chunk`, `whenmod`, `off` passent par `_same_patterns` et construisent `f(p)` une seule fois.
- [x] M3 — `"<a b>*2"` accélère l'alternance (`RepeatNode`, `core_mininotation.jl:497`).
- [x] M4 — Tous les signaux vivent dans `[0, 1]` comme dans Tidal (`sine`, `cosine`, `tri` compris ; modulateurs chaos et reservoir aussi, `raw = true` pour l'état brut) ; `range_pat` / `rangex` partent de `[0, 1]`.
- [x] M5 — Aléatoire : un seul tirage `_u01` (hash + splitmix64) ; reproductible et, comme dans Tidal, identique d'un combinateur à l'autre par défaut — `seed = n` décorrèle (`degradeBy`, `sometimes*`, `unDegradeBy`).
- [x] M6 — Mini-notation : `"0 ! 3"`, `"0? 3"`, poids dans `<>` (`@`, `_`), `"[a|b] [a|b]"`, `"1e3"`, `"<a b, c d>"`, Euclide invalide refusé au parse, Bjorklund à la place de la formule fermée (rythmes de référence (3,8) (5,8) (2,5) (3,7) (4,9) (5,12) (7,16) conformes ; pas confronté à un Tidal qui tourne).
- [x] M7 — `stack(q)` à un argument, `layer([f], p)` ; `"bd:x"` toléré, `_split_variant` source unique.
- [x] M8 — `walk` / `markov` ne rejouent plus depuis le cycle 0 à chaque requête.
- [x] M9 — Sockets : `OSCClient` fermé à `stop_live!`, `bind` raté sans fuite, boucle d'écoute qui ne tourne pas à vide sur erreur.

## Phase 3 — Synthèse : parseur SC, DSL, génome

- [x] S1 — Le parseur SC échoue franchement (`ScParseError`, raison rendue par `parse_sc_expr` / `parse_dsl_synth` / `synthdef_to_dsl_reason` et dite au joueur) : identifiant inconnu, texte non lu, mot-clé sans place. `mul:` / `add:` et arguments nommés du catalogue posés ; tableaux (`:Chan`), références (`:Ref`), symboles et `nil` (`LitArg`) conservés ; commentaires sautés. Audition et analyse ramènent un son multicanal à la moyenne de ses voies.
- [x] S2 — `var x = expr;` lu comme une affectation (`sc_synthdef.jl:76`).
- [x] S3 — Priorité gauche-à-droite de SC dans le parseur (`sc_expr_parse.jl:204-260`).
- [x] S4 — `chorus` et `phaser` parenthésés (`synth_dsl.jl:334`, `:359`).
- [x] S5 — Méthodes, méthodes de classe et opérateurs sans fiche gardés sous leur nom (`Symbol(".abs")`, `Symbol("Env.triangle")`, `Symbol("**")`) et rendus en SC valide ; `abs` / `sqrt` / `pow` entrent au catalogue ; `.neg` est un `* -1`.
- [x] S6 — Rendus tolérants à l'arité (`LFPulse.kr(2)`, phase de `SinOsc.kr` conservée) ; `Mix.ar([…])` devient la somme de ses voies. Pas de complétion par les défauts du catalogue : ce ne sont pas ceux de SC.
- [x] S7 — `.range` unipolaire pour LFPulse, Impulse, Dust, Trig, EnvGen.
- [x] S8 — Mutation : nœuds hors catalogue ignorés ; perturbation multiplicative hors plage ; `op_insert_node!` place le signal dans le bon slot ; `op_swap_ugen!` remappe par nature de slot.
- [x] S9 — Enveloppe auto : test sur `doneAction` et non sur la sous-chaîne `EnvGen` (`synth_dsl.jl:727`).
- [x] S10 — Une seule fonction `sc_num` (Rational, π, `inf`, NaN refusé, grands flottants) ; `sc_sym` accepte un nombre ; courbe `\sin` conservée.
- [x] S11 — Un nom de synth est un identifiant (`valid_synth_name`) : vérifié dans `build_synth`, `render_dsl`, `render_synthdef`, et à la saisie dans l'explorateur.
- [x] S12 — Faux positif, vérifié : audition et export disent la même chose. Un nœud lu deux fois est recopié des deux côtés (dans le DSL, `n = white()` lu deux fois écrit deux `WhiteNoise.ar`). Ce qui manque est une fonctionnalité — voir F5.
- [x] S13 — `register_synth!` en upsert : les `params` du DSL arrivent (les six `chao*`, ré-évaluation par T).
- [x] S14 — `audition_hold!` utilise `freq` et `sustain`.
- [x] S15 — `:export` d'un synth DSL passe par le chemin de T (`app_transport.jl:103`) (lecture).

## Phase 4 — TUI

- [x] U1 — Tout découpage dérivé du curseur se fait en caractères : opérateurs vim, visuel, `_pat_at_cursor`, nudge, insertion du navigateur. Au passage : `de` / `ye` (le `e` n'évalue plus la ligne quand un opérateur attend), `d$` `c$` `d0`, et `dw` sur le dernier mot d'une ligne s'arrête à la fin de la ligne comme vim.
- [x] U2 — Une seule porte : `_edit_text!` (annulable, défilement gardé) pour toute édition, `_load_text!` pour remplir un buffer neuf (`editor_edit.jl`) ; plus aucun `set_text!` direct sur un éditeur (règle testée).
- [x] U3 — `:layout load` charge à côté et n'échange qu'en cas de succès ; `on_close!` sur les anciennes panes ; erreur visible.
- [x] U4 — Scinder partage la place de la pane scindée (comme tmux), fermer la rend à la voisine : ouvrir puis fermer redonne la disposition. Rendu et frontières lisent `_child_areas`, qui pave l'aire exactement.
- [x] U5 — Scopes transitoires (`:pane_mode`, `:visual`, `:insert`, `:placeholder`, `:tap`, `:piano`) avec de vraies actions dans le registre ; `m` / `e` en visuel sur la sélection ; `d$` `c$` `d0` ; Ctrl-f ; `/` câblé ; `04-keys.md` régénéré.
- [x] U6 — Cible résolue par mode et non par pane focalisée : `e`, `m`, `:w`.
- [x] U7 — `E` et `e` d'accord sur les slots multi-lignes (`_logical_block_range`).
- [x] U8 — `_ensure_synth_workspace!` repose ce qui manque autour de l'arbre existant, sans rien jeter ; un seul chemin de changement de workspace (`_switch_workspace!`) pour `:design`, Ctrl-1..9 et le clic.
- [x] U9 — État du placeholder et ancres visuelles par buffer, validés.
- [x] U10 — Travail lent hors de la tâche UI (`_background!` / `_drain_jobs!`, app_jobs.jl) : liste, pages et import sccode, mesure d'impact de `:prune` ; `:vsplit bogus` loggé.
- [x] U11 — Code mort : mode commande du CodeEditor, fonctions vim jamais appelées, `_COMMAND_NAMES`, `"harvest"`, `"save-synth-as"`, champs vestigiaux, `_next_free_d_slot` / `_next_free_slot` unifiés.
- [x] U12 — Une seule grille de candidats (`_render_candidate_grid!`, pour l'éditeur et la barre de commande — Tachikoma n'a pas de liste multi-colonnes) ; les rangées de catégories des modales passent par `TK.TabBar`.

## Phase 5 — Plugins

- [x] P1 — Tachikoma épinglé (`=2.1.0`) et patches conditionnés à `pkgversion`.
- [x] P2 — `restart_live!` repart de registres propres ; un plugin qui se ré-enregistre remplace ses entrées.
- [x] P3 — Un snippet ou une fiche mal formés n'emportent plus le reste de la section.
- [x] P4 — Ordre des sections explicite (plus d'ordre de hachage).
- [x] P5 — Une seule règle pour tous les registres (`_register!`) : le même plugin se remplace en silence, un autre plugin chargé après l'emporte avec un avertissement (`core` est chargé en premier pour qu'on puisse le surcharger ; c'est aussi ce que SC fait d'un SynthDef redéfini). Docstring de `default_plugin_path` corrigée.
- [x] P6 — `bootstrap.jl` dans un module ; découverte `@synth` en début de ligne.

## Phase 6 — Dépôt et docs

- [x] D1 — `just live-fast` ne lance plus une image plus ancienne que `src/` : il le dit et démarre depuis les sources.
- [x] D2 — `recordings/*.wav` et `sessions/_last.txt` sortis de l'index (les fichiers restent sur le disque), `recordings/` ignoré, `sessions/.keep` créé. `plugins/user-synths` : les fichiers déjà suivis restent des exemples, les nouveaux exports restent non suivis (décision déjà prise le 2026-09-21).
- [x] D3 — `Project.toml` : `TerminalUserInterfaces` retiré, `Supposition` en dépendance de test, `PackageCompiler` hors du projet (`scripts/build_sysimage.jl` le charge d'un environnement partagé `@ressac-sysimage` ; vérifié en `RESSAC_SYSIMAGE_DRYRUN=1`, pas par une construction complète), bornes des stdlibs, `Dates = "1"`.
- [x] D4 — Compteurs de tests retirés du README, de CONTRIBUTING et du justfile.
- [x] D5 — Anciens noms de fichiers dans CONTRIBUTING, `ressac.toml`, commentaires et en-têtes de tests.
- [x] D6 — CHANGELOG rattrapé depuis le 2026-05-25.

## Phase 7 — L'écran unique (refonte de l'expérience)

Décidée le 2026-11-17. Détail des tâches, tests et risques : `docs/journal/20261117_ecran_unique_plan.md`. Réflexion et maquettes dans le même dossier.

- [ ] E0 — Mesures : temps pour refaire un son, signes de solfège dans kitty, ligne éclairée dans Tachikoma, égalité des 18 `.scd` convertis.
- [x] E1 — L'état de chaque ligne (`SlotState`) : joue, muet, modifié, en erreur, tenu, hors grille.
- [x] E2 — L'écran unique : marge, erreur sous la ligne, piste au bout de la ligne, volet à droite (fiche / wiki / son). Fin des workspaces PLAY / DESIGN / EXPLORE. *(Restent deux détails : poser un exemple du wiki dans un slot, et « voisins / pas encore essayé » dans la fiche, qui attend E4.)*
- [x] E3 — Sessions avec les verbes de vim (`:w` `:e` `:enew`), réserve unique.
- [x] E4 — Un seul langage : zéro `.scd`, nombres à trois décimales, usage compté, pipes en tête, `gcc`.
- [x] E5 — L'atelier : réglette, objet texte `m`, complétion qui s'entend, `&`, explorateur sur un slot. Fin du studio et de sculpt.
- [x] E6 — Hors grille : `Entrée` = maintenant, `frappes`, la boucle.
- [x] E7 — Le casque en delta, découverte des sorties PipeWire. *(Codé et testé sans matériel ; reste à l'entendre avec SuperCollider lancé.)*

## Phase 8 — Le langage visuel (refonte « A + D »)

Décidée le 2026-11-19 sur maquettes. Le système et ce qui reste : `docs/journal/20261119_refonte_visuelle.md`.

- [x] V1 — La palette (`ui_style.jl`), le thème `ressac`, la dernière passe du rendu (fonds et couleurs exactes).
- [x] V2 — Plus de cadres ni de boutons de fenêtre : bandes de titre, filets, ligne du haut, ligne d'état.
- [x] V3 — La grille du cycle : temps alternés, pistes nommées, tête de lecture pleine hauteur, notes en chiffres.
- [x] V4 — La fiche en colonne de lecture, avec ses bandes LIGNE et EN JEU.
- [x] V5 — Les fenêtres recouvrent et éteignent le reste ; le menu Espace en panneau.
- [x] V6 — L'écran d'un son : texte et DOC côte à côte entre 165 et 200 colonnes (au-delà, la fiche garde sa colonne), la chaîne en tableau en tête de l'explication.
- [x] V7 — Le menu Espace rangé par intention ; l'explorateur en tuiles sans cadres.
- [ ] V8 — Les fenêtres à table (réserve, mixer, sorties, palette) : colonnes nommées, aperçu d'un motif sur la grille, plus de filets internes.

## Fonctionnalités (ancien `TODO.txt` et wiki)

- [ ] F1 — Snippets : éditeur de snippets et alias de snippets (les raccourcis `:sg0.9` / `:sng…` existent déjà) ; table du leader sortie du code (`editor_snippets.jl:64`).
- [ ] F2 — Les plugins contribuent des pages de wiki (`content_wiki.jl:26` ne lit que `docs/wiki/`).
- [ ] F3 — `nTake`, `numerals`, `fix` avec fonctions d'état.
- [ ] F4 — Entrée MIDI native (aujourd'hui : pont OSC, wiki 13).
- [ ] F5 — `shared(x)` dans le DSL : lire deux fois le MÊME signal (un bruit scindé en deux bandes puis recombiné). Aujourd'hui une variable Julia recopie son expression, et `:todsl` inline de même les `var` d'un SynthDef : deux lectures d'un bruit sont deux bruits.
