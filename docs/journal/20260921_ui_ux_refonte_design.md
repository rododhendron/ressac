# Refonte UI/UX + structure du code — design

Date : 2026-09-21. État de départ : commit `0e62127` (sculpt bricks 2-7,
modal extrait), suite verte (3145 tests).

Ce document part d'un **constat mesuré** (captures headless de la TUI,
inventaire du code), rappelle **ce qui fait qu'une TUI est agréable** chez
les outils de référence, puis propose une **cible** et un **ordre de
livraison**. Les décisions ouvertes sont listées à la fin.

## 1. Constat

### 1.1 Comment on a regardé

`scripts/tui_shot.jl` construit une `RessacApp` avec un scheduler à OSC
mocké, rejoue des scénarios de touches, et dumpe chaque frame rendue
(`Tachikoma.TestBackend`) en texte. C'est la même mécanique que
`test/test_visual_integration.jl`, donc tout ce qui est vu ici est
assertable en test. 25 captures ont servi de base à ce constat
(initial, `?`, `:`, modaux, vsplit, explorer, sculpt, wiki, scope…).

### 1.2 `?` — l'aide n'est pas cassée, elle est locale et incohérente

- `?` ouvre le guide **uniquement** depuis la pane patterns en mode normal
  (`tui_app.jl`, dispatch clavier). Depuis une pane synth, log, doc,
  waveform, tuning, scope : rien ne se passe. L'explorer a son propre `?`
  (aide locale, en français), qui n'ouvre pas le guide global.
- Dans le guide, `?` ne referme pas (q/Esc seulement) — pas de toggle.
- **Sept sources d'aide** qui dérivent les unes des autres à la main :
  `_GUIDE_LINES` (modal), les hints du footer (5 variantes codées en dur
  dans `_render_footer`), `_MODE_HINTS` et `_HELP_OVERLAY_LINES`
  (**morts** — plus aucune référence), le `title_right` de chaque modal,
  la ligne de hints propre à chaque pane (explorer, waveform),
  `docs/wiki/04-keys.md`, `_TUTORIAL_LINES`. Exemple de dérive : le guide
  promet « Tab — swap focus patterns/synth », le footer de l'explorer
  affiche les hints de la pane patterns.
- Langue : l'aide et le chrome sont en anglais (guide, footer, wiki), les
  panes récentes (explorer, sculpt) en français.

### 1.3 Chrome — 15 lignes sur 40

Sur un terminal 140×40 : 1 ligne status en haut, puis en bas
`[1]` (workspace strip), `NORMAL · insert · visual · command · search ·
pane` (mode strip qui liste tous les modes en permanence), la ligne
livedoc (vide sauf curseur sur un mot documenté), le footer de hints, et
la boîte LOG de 10 lignes. Soit 15 lignes de chrome, 37 % de l'écran,
dont deux lignes quasi toujours vides.

Quand un modal est ouvert, la barre de commande persistante écrit
`: commande` sur la bordure basse de la boîte LOG (artefact visible sur
toutes les captures de modaux).

### 1.4 Conteneurs et titres incohérents

| Surface | Conteneur | Titre |
|---|---|---|
| patterns, synth | pane éditeur | `PATTERNS`, `SYNTH · kick` |
| explorer | pane | **aucun** |
| waveform, scope, tuning, doc, log | pane | `LOGS` (vs boîte chrome `LOG`) |
| browse, lib, snip, wiki, mixer, guide, explain, tutorial | modal | oui |
| sculpt | **modal** qui rend une WaveformPane | oui |

Deux systèmes de hints se marchent dessus : le footer global (contexte
patterns/synth) et la dernière ligne des panes explorer/waveform.

### 1.5 Le pont son ⟷ patterns est fragile

- `:synth kick` ouvre un **starter vide** nommé kick, alors que la
  librairie contient un kick. Seul `:lib` + Enter ouvre la recette
  (`_open_synth_tab!` ne consulte pas `_SYNTH_LIBRARY`).
- `:sculpt <nom>` échoue (« pas un synth DSL reconnu ») sur tout synth
  sans génome embarqué : les exports d'avant juin (`Sig("{ … }")`), tous
  les `.scd`, et même le starter une-ligne (`genome_from_dsl` ne parse
  que la forme `begin … end`). Testé : `:sculpt pebblesaw` échoue,
  `:sculpt` sur le kick starter échoue.
- Trois chemins pour « aller travailler un son » : `:synth` (pane),
  `:vsplit explorer` (pane, commande non documentée dans le guide),
  `:sculpt` (modal). Et aucun chemin direct pour « utiliser ce son dans
  un pattern » depuis la pane synth, ni « éditer le synth sous le
  curseur » depuis patterns (`K` ne fait qu'écouter).

### 1.6 Structure du code

- `src/tui_app.jl` : **6134 lignes, ~170 fonctions, une dizaine de
  responsabilités** : le modèle `RessacApp` (250 lignes de champs),
  le routage clavier/souris, les motions vim (`_word_motion!`,
  `_op_with_motion!`… ~400 lignes alors que `tui_editor_ops.jl` existe),
  le registre ex + ~110 commandes et leurs handlers (session, tuning,
  alias, SC, scope, mute/solo…), l'eval (`_eval_pattern_blocks!`,
  cascade, ~350 lignes), le rendu du scope (12 `_app_render_*`, ~600
  lignes, alors que `tui_scope.jl` et `pane_scope.jl` existent), la
  gestion des tabs synth, le layout/chrome, les modaux génériques.
- Code mort : `_MODE_HINTS`, `_HELP_OVERLAY_LINES`, `_mode_hint`,
  `_command_arg_candidates`, `_wrap_text`, `reshuffle!`.
- `docs/wiki/10-architecture.md` décrit `app.jl`, `tui.jl`,
  `scheduler.jl`, `osc.jl`… — des noms qui n'existent plus.
- Tests : `test_ui_integration.jl` dépend de l'ordre de la suite
  (connu), et rien n'asserte la géométrie du chrome (pas de test « la
  dernière ligne est la bordure du log », d'où l'artefact 1.3).

## 2. Ce qui est admis comme agréable (références)

| Outil | Ce qu'on retient |
|---|---|
| **lazygit** | Panneaux numérotés, focus par chiffre. Barre du bas = touches **du panneau focalisé**. `?` ouvre la liste des raccourcis **du contexte courant**. |
| **helix** | Status line : badge de mode à gauche, contexte à droite. Préfixes (`Space`, `g`, `z`) ouvrent un **popup which-key** listant les suites possibles. Une seule table de bindings génère la doc. |
| **zellij** | Barre persistante qui affiche le **mode courant et les modes accessibles** avec leur touche. Les modes (pane/tab/resize) sont découvrables sans lire de doc. |
| **k9s** | `:` change de « ressource » = change de vue. Hotkeys du contexte dans l'en-tête. Fil d'Ariane. |
| **tmux** | `z` zoome une pane plein écran et revient. Un seul prefix pour toutes les actions de layout. |

Dénominateurs communs :

1. **Une seule source de vérité pour les touches** → hints, aide, doc
   sont générés, jamais recopiés.
2. **L'aide est contextuelle** : `?` montre d'abord ce que la surface
   focalisée sait faire, puis le global. `?` marche partout et toggle.
3. **Découvrabilité par popup** sur les préfixes (which-key) plutôt que
   par lignes permanentes.
4. **Chrome minimal** : une status line, une barre de touches, point.
5. **Conteneurs cohérents** : modal = choix transitoire (picker, aide) ;
   pane = surface de travail. Une surface de travail se zoome, ne
   devient pas un modal.
6. **Un mode = un état visible** dans la status line, avec sa couleur.

## 3. Cible

### 3.1 Registre de bindings (fondation)

```julia
struct Binding
    key::String          # "?", "Space d", "Ctrl-w s", "gt"
    label::String        # court : "aide", "eval", "swap UGen"
    scope::Symbol        # :global, :patterns, :synth, :explorer, :sculpt, :modal_lib …
    action::Function     # (m) -> …  ou (pane) -> …
    when::Function       # prédicat de disponibilité (mode normal, pane ouverte…)
    group::Symbol        # :nav, :edit, :audio, :layout, :help — pour l'aide
end
```

Déclaré par pane kind (`bindings(::Type{SynthExplorerPane})`) et pour le
global. Consommateurs :

- **Barre de touches** (bas) : les N premiers bindings disponibles du
  scope focalisé, puis global. Remplace `_render_footer` et les lignes de
  hints propres aux panes.
- **Aide `?`** : modal groupé par scope (focalisé d'abord), généré.
  `?` global, toggle, disponible dans tout pane et tout modal.
- **Which-key** : popup sur `Space`, `g`, `Ctrl-w`, `:` (liste des
  commandes) après ~300 ms ou immédiatement (à décider), listant les
  suites.
- **`docs/wiki/04-keys.md`** : généré par un script (ou un test qui
  échoue si la page diverge du registre).

Le dispatch clavier existant (`TK.update!`, ~550 lignes de `if/elseif`)
devient : command line → panic → pane mode → modal → registre du pane
focalisé → registre global → fallback éditeur. Les prédicats `when`
remplacent les `_focused_role(m) === :patterns && ed.mode === :normal`
dispersés.

### 3.2 Chrome : de 15 lignes à 3

```
▓ RESSAC  ♪ 0.5 cps · 120 bpm  ◐ ████░░░░  ✧ 128 │ NORMAL │ PATTERNS │ ● REC 00:42   [1 PLAY] 2 DESIGN 3 EXPLORE
┌─ PATTERNS ───────────────┐┌─ SYNTH · kick ────────────┐
│ …                        ││ …                         │
└──────────────────────────┘└───────────────────────────┘
 ? aide · e eval · E tout · m mute · Space snippet · : cmd          ✎ gain — amplitude 0..1
▎ [INFO] opened synth 'kick'                                                             (3 lignes, repliable)
```

- **Status line** (haut) : logo, tempo, cycle, events, **badge de mode
  coloré**, **nom de la surface focalisée**, états (rec/tap/piano), et
  les workspaces à droite (fusion du workspace strip).
- **Barre de touches** (bas) : générée depuis le registre ; la livedoc
  du mot sous curseur s'affiche à droite de cette même ligne quand elle
  existe (plus de ligne dédiée vide).
- **Log** : 3 lignes repliables (`:log` bascule 0/3/10, ou pane log
  pour le plein). Les modaux n'écrivent plus sur la bordure du log : la
  barre de commande persistante prend la ligne de la barre de touches.
- Suppression du mode strip (l'info est dans le badge).

### 3.3 Trois espaces de travail nommés = trois façons de travailler

Les workspaces existent déjà (`Ctrl-1..9`). On les nomme et on les
pré-remplit :

| Workspace | Contenu | Pour |
|---|---|---|
| **1 PLAY** | patterns + log (3 lignes) | jouer, écrire des patterns |
| **2 DESIGN** | éditeur synth + waveform/scope | écrire/tester un son |
| **3 EXPLORE** | explorer + sculpt (waveform sculpt + explainer) | chercher un son |

`Ctrl-1/2/3` ou `:play` / `:design` / `:explore` basculent. La status
line montre où on est. Les ponts entre espaces, en une touche :

- Depuis patterns, curseur sur `kick` : **`gs`** (go synth) ouvre le
  synth sous le curseur dans DESIGN (librairie, user-synths, ou starter
  si inconnu). `K` continue d'écouter.
- Depuis un synth (DESIGN ou sculpt) : **`U`** (use) insère
  `@dN p"…" |> s(:nom)` sur la première ligne libre de patterns et
  bascule dans PLAY. Le sculpt sauve d'abord (`:w` implicite avec le
  label courant).
- Depuis l'explorer : `e` (déjà) ouvre le candidat dans DESIGN ; `M`
  (déjà) l'ouvre dans le sculpt.
- `:synth <nom>` ouvre la **recette de librairie** si elle existe (copie
  éditable), sinon le fichier user, sinon le starter.
- `:sculpt` accepte tout DSL parsable (formes une-ligne et bloc) ; pour
  un `.scd` ou un vieux `Sig("…")`, message explicite : « pas
  sculptable : synth SC brut — :synth pour l'éditer ».

### 3.4 Conteneurs

- **Modaux** = pickers et aide : browse, lib, snip, wiki, mixer, aide,
  explain, tutorial. Tous via `_open_modal!`, même chrome, même
  `title_right` généré depuis le registre.
- **Panes** = surfaces de travail : patterns, synth, explorer, waveform
  (sculpt ou vue), scope, tuning, doc, log. Toutes titrées (l'explorer
  prend `EXPLORER · gén 4 · tune`).
- **Zoom** : `Ctrl-w z` (ou `Z`) maximise la pane focalisée plein écran
  et revient. Le studio sculpt devient « waveform sculpt + explainer »
  dans EXPLORE, zoomable — plus un modal à part. (Décision ouverte,
  voir §5.)

### 3.5 Structure du code

Découpage de `tui_app.jl` en **déplacements purs** (aucun changement de
comportement, suite verte après chaque fichier) :

| Nouveau fichier | Contenu déplacé | ~lignes |
|---|---|---|
| `app_model.jl` | `RessacApp`, accesseurs (`_active_editor`, `_focused_role`…) | 400 |
| `app_keymap.jl` | registre `Binding` + which-key + aide générée (nouveau) | 300 |
| `app_update.jl` | `TK.update!` clavier/souris, routage vers panes/modaux | 500 |
| `app_view.jl` | `TK.view`, status line, barre de touches, log tail, arbre | 500 |
| `app_commands.jl` | registre ex (`_register_*`), historique, complétion | 250 |
| `app_commands_*.jl` | handlers groupés : session, tuning, alias, sc, scope, synth, layout | 900 |
| `app_eval.jl` | eval ligne/blocs, cascade `@dN`, flash | 400 |
| `app_synth_tabs.jl` | ouvrir/fermer/sauver/tester un synth | 350 |
| `tui_editor_ops.jl` (existant) | + motions vim, nudge, shortcuts patterns | +500 |
| `tui_scope.jl` (existant) | + les 12 `_app_render_*` | +600 |
| `modal_*.jl` (existants) | + guide/tutorial/explain génériques | +100 |

Plus : suppression du code mort (§1.6), `tui_hints.jl` réduit à la
complétion, `docs/wiki/10-architecture.md` réécrit sur la carte réelle
(`Ressac.jl` l'ordre d'include est déjà la bonne table des matières).

### 3.6 Tester l'UI

- `scripts/tui_shot.jl` reste comme outil de revue visuelle (captures
  texte, diffables dans un commit).
- Tests visuels de **géométrie du chrome** : la dernière ligne est
  toujours la bordure du log ou la barre de touches ; aucun modal ne
  déborde sur le chrome ; chaque pane a un titre ; la barre de touches
  change avec le focus.
- Tests du registre : chaque `Binding` a un label, chaque touche du
  wiki existe dans le registre (et inversement).
- Rendre `test_ui_integration.jl` indépendant de l'ordre (état global
  `_PANE_MODE`, `_APP_LOG`, registres) via un `setup!` commun.

## 4. Ordre de livraison

1. **Structure** — découpage de `tui_app.jl` en déplacements purs, code
   mort retiré, wiki architecture réécrit. Aucun changement visible.
2. **Registre de bindings** — `?` global et toggle, barre de touches
   générée, aide générée, which-key sur `Space`/`g`/`Ctrl-w`. Tests
   registre + visuels.
3. **Chrome** — status line fusionnée, suppression mode strip/livedoc
   row, log repliable, barre de commande sans artefact.
4. **Ponts son ⟷ patterns** — workspaces PLAY/DESIGN/EXPLORE, `gs`, `U`,
   `:synth` librairie, `:sculpt` robuste.
5. **Conteneurs** — titres partout, zoom de pane, sculpt en pane zoomable
   (si décidé).
6. **Langue** — harmonisation de l'UI (voir §5).

Chaque étape : design→tests→impl, suite complète verte, un commit par
brique, comme pour le sculpt.

## 5. Décisions ouvertes

1. **Sculpt : modal plein écran (actuel) ou pane zoomable dans EXPLORE ?**
   Recommandation : pane zoomable — même conteneur que le reste, patterns
   reste visible/jouable pendant qu'on sculpte, et le studio devient
   sauvegardable dans un layout.
2. **Log : 3 lignes repliables (recommandé) ou garder 10 lignes ?**
3. **Langue de l'UI : français (recommandé, c'est la direction des
   derniers modules) ou anglais (état du guide et du wiki) ?** Le code et
   les commits restent comme ils sont.
4. **Which-key : immédiat ou après délai ?** Recommandation : immédiat sur
   `Space` en mode normal (c'est déjà un leader), après 300 ms sur `g` et
   `Ctrl-w` pour ne pas gêner les habitués.

## 6. Risques

- Le découpage pur de 6000 lignes touche l'ordre d'include : Julia
  résout les noms à l'appel, donc seuls les `const` et les `struct`
  imposent un ordre. On garde `Ressac.jl` comme unique table d'includes.
- Le registre remplace un dispatch `if/elseif` qui encode des priorités
  implicites (panic avant tout, `e` selon la pane…). Les prédicats `when`
  doivent reproduire ces priorités ; les tests UI d'intégration existants
  (1500 lignes) servent de filet.
- Les workspaces nommés changent le premier écran : le tutoriel et
  `_STARTER_BUFFER` doivent être relus.
