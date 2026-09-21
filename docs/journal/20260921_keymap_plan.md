# Registre de bindings — plan (étape 2 de la refonte UI)

Design : `20260921_ui_ux_refonte_design.md` §3.1. Principe : **une seule
table par scope** ; la barre de touches, l'aide `?`, le popup which-key
et le wiki des touches en dérivent. Le dispatch clavier passe par elle
pour toutes les *actions* ; le moteur d'édition vim de Tachikoma
(motions, opérateurs, insert, `:` de l'éditeur) reste le fallback et
n'est documenté que par des entrées sans action.

## Inventaire (ce qui existe et doit être conservé)

| Scope | Touches aujourd'hui | Où |
|---|---|---|
| global | `!` panic · `,` hush · `:` `/` · `Ctrl-w` · `Ctrl-1..9` · `Ctrl-F` floats · `S` scope · `?` (patterns seulement) | app_input.jl |
| patterns | `e` `E` `m` `K` · Space leader · `v` `V` · `.` · `+ - * /` nudge · `> < H L X` dans p"…" · Tab swap | app_input.jl |
| synth | `t` `T` Space test (repeat) · `gt` `gT` · Tab swap | app_input.jl |
| scope (global) | `+ - = > <` zoom quand :wave / reservoir | app_input.jl |
| leader Space | 18 snippets + b L I w ? | tui_leader_snippets.jl |
| mode pane | s v h j k l c · Esc/Enter/Ctrl-w sortir · flèches | workspace_keymap.jl |
| explorer | 40 touches + sous-modes (naming, inspect, lineage, help, explain, ga_panel, param_edit, keyboard) | pane_synth_explorer.jl |
| waveform / sculpt | `s` · j k Tab S-Tab h l `=` o O n d i I r R x m L H Space Enter e 0 · vue : h l + - i o 0 | pane_waveform.jl |
| log / doc / tuning | j k · j k · r | pane_*.jl |
| modaux | guide (j k g G q) · browse · lib · mixer · wiki · snip · sccode · sculpt | modal_*.jl, app_modal.jl |
| tap / piano | Space Enter Esc · lettres `[` `]` | app_input.jl |

## Tâches

### T1 — Registre pur `src/keymap.jl` + `test/test_keymap.jl`
`Binding`, `bind!`, `bindings(scope)`, `keyname(evt)` (nom canonique d'une
touche : "Space", "Tab", "S-Tab", "Esc", "Enter", "Ctrl-w", "↑", "PgDn"…),
accords à préfixe ("Space d", "g t", "Ctrl-w s"), `dispatch!` sur une
liste (scope, cible) ordonnée avec prédicat `when` et `repeat`,
`prefix_bindings` (which-key), `help_sections` (aide groupée),
`keymap_conflicts` (deux bindings actifs sur la même touche du même
scope = erreur de test). Titres de scope en français.

### T2 — Bindings déclarés, dispatch app
`src/app_keymap.jl` : déclarations :global / :patterns / :synth / :editor
(doc) / :leader (dérivé de `_LEADER_*`) / :pane_mode / :tap / :piano /
:visual / :insert / :command. `TK.update!` : la chaîne `if/elseif` des
actions devient `dispatch!` sur `[pane focalisée, :synth|:patterns,
:global]` avant le fallback éditeur. Les prédicats `when` reproduisent
les gardes actuelles (mode normal, pane ouverte, nombre sous le curseur,
curseur dans p"…", scope :wave…). Tests UI existants = filet ; ajout
d'un test « chaque touche de l'inventaire est toujours dispatchée ».

### T3 — Panes et modaux sur le registre
Chaque `PaneImpl` déclare `bindings(::Type)` ; `handle_key!` devient :
garde des sous-modes (inchangée) → `dispatch!` → fallback. Idem pour
les `_handle_*_key!` des modaux (scope :modal_x). L'aide locale de
l'explorer (`_EXPLORER_HELP_LINES`, `show_help`) et sa ligne de hints
disparaissent au profit du registre.

### T4 — `?` global, aide générée, toggle
Modal :help : sections = scope focalisé, puis global, puis éditeur,
puis le reste replié (`Tab` déplie tout). `?` fonctionne dans toute
pane et tout modal (depuis un modal : aide de ce modal, retour au modal
à la fermeture). `?`/Esc/q ferment. `:guide`, `:help`, `Space ?` →
:help. `_GUIDE_LINES` réduit à sa partie référence (mini-notation,
effets, commandes) affichée en queue de l'aide.

### T5 — Barre de touches générée
`_render_footer` → `_render_keybar!` : bindings `hint=true` disponibles
du scope focalisé (ordre de déclaration), puis global, tronqués à la
largeur ; leader pending → bindings :leader. Suppression des lignes de
hints propres aux panes (explorer, waveform) et des `title_right` codés
en dur des modaux (générés depuis le scope).

### T6 — Which-key
`m.prefix_since` ; popup au-dessus de la barre de touches : Space
(immédiat), `g` et `Ctrl-w` (après 300 ms, `ed.pending_key`/
`_PANE_MODE.active`). Rendu depuis `prefix_bindings`. Test visuel.

### T7 — Wiki des touches généré
`scripts/gen_keys_wiki.jl` écrit `docs/wiki/04-keys.md` (français) depuis
le registre ; test qui échoue si la page diverge du générateur.

### T8 — Captures + tests de géométrie
`scripts/tui_shot.jl` mis à jour ; tests : la barre change avec le focus,
`?` depuis synth/log/explorer ouvre le bon scope, which-key visible.

Chaque tâche : tests d'abord, suite complète verte, un commit.
