# Architecture

Comment une touche devient du son, et quel fichier possède quoi. Utile
pour contribuer, déboguer un pattern qui ne joue pas, ou par curiosité.

## La version en 30 secondes

```
ta touche
      ↓
boucle terminal Tachikoma (~/.julia/packages/Tachikoma)
      ↓ KeyEvent
src/app_input.jl :: TK.update!(m, evt)
      ↓ mute l'éditeur / le scheduler
src/io_scheduler.jl :: _step! (tâche de fond, toutes les lookahead/2 s)
      ↓ interroge les patterns, construit les bundles OSC
src/io_osc.jl :: encode → datagramme UDP
      ↓
SuperCollider / SuperDirt (port 57120)
      ↓
tes enceintes
```

Tout Ressac vit dans **un seul module Julia** nommé `Ressac`. Pas de
frontière de module à l'intérieur : les fichiers s'`include`nt dans
l'ordre fixé par `src/Ressac.jl`, qui est **l'unique table des
includes** et donc la meilleure table des matières. Le découpage suit la
responsabilité, pas la visibilité.

## Qui possède quoi

```
src/
  Ressac.jl                ★ racine du module : ordre d'include + exports

  ── Domaine pur (aucune I/O) ──
  core_patterns.jl         ★ Pattern{T}, Event{T}, query
  core_mininotation.jl       le parseur de p"…"
  core_combinators.jl        fast/slow/jux/every/sometimes/…
  core_algebra.jl            stack/cat/mask
  core_tuning.jl             Scale, registre des gammes
  core_controls.jl           gain/lpf/hpf/pan/n/… (les |> )

  ── I/O ──
  io_osc.jl                  format OSC (encode/decode, pas de réseau)
  io_scheduler.jl          ★ la boucle temps réel — le chemin chaud.
                             Voir « discipline de verrou » plus bas.

  ── Session live ──
  live_boot.jl               _LIVE_SCHEDULER, start_live!, live()
  live_api.jl                @d1..@d64, hush_all!, cps!, _route_to_slot!

  ── Plugins ──
  plugin_registry.jl       ★ _SAMPLE/_INSTRUMENT/_SYNTH_REGISTRY + loader
  plugin_handlers.jl         [samples] [instruments] [synths] [julia]
  extension_registry.jl      docs + snippets apportés par les plugins

  ── Synthèse ──
  synth_dsl.jl               SynthDSL : Julia → SC à la compilation
  synth_library.jl           recettes DSL intégrées (kick, acid303, …)
  genome*.jl, ga_*.jl        explorateur GA : génome, validité, rendu,
                             opérateurs, moteur, ciblage, analyse
  nrt_analysis.jl            descripteurs acoustiques hors-ligne
  synth_roles.jl             rôles d'usage (bass/kick/…) + adéquation
  synth_explainer.jl         « pourquoi ça sonne comme ça » + genome_from_dsl
  synth_audition.jl          écoute des candidats (OSC)
  wave_sculpt.jl             sculpt : knobs, proximité, bricks structurels

  ── Panes (workspace) ──
  pane_interface.jl        ★ contrat PaneImpl + register_pane_kind!
  workspace_manager.jl       arbre de splits, focus, floats, workspaces
  workspace_commands.jl      cmd_split!/cmd_close!/cmd_focus!/…
  workspace_keymap.jl        mode pane (Ctrl-w …)
  workspace_persistence.jl   :layout-save / :layout-load
  pane_editor.jl             EditorPane (patterns et synth)
  pane_log.jl, pane_doc.jl, pane_scope.jl, pane_tuning.jl
  pane_synth_explorer.jl     :explorer (GA)
  pane_waveform.jl           :waveform (vue d'onde + mode sculpt)
  snippet_panes.jl           panes créées par :snippet
  command_line.jl            la barre `:` / `/` (widget indépendant)

  ── L'application (chaque fichier prend un m::RessacApp) ──
  app_model.jl             ★ RessacApp + accesseurs (_active_editor,
                             _focused_role, …) + workspace par défaut
  app_input.jl             ★ TK.update! clavier/souris : barre de
                             commande → panic → mode pane → modal →
                             pane focalisée → flux patterns
  app_editor.jl              motions vim, nudge des nombres, raccourcis
  app_patterns.jl            mute/solo, preview, eval @dN + cascade
  app_scope.jl               :scope + rendu des 12 vues
  app_synth.jl               panes synth : ouvrir/fermer/sauver/tester
  app_transport.jl           rec / export / panic / hush
  app_commands.jl            tables ex (littéral/regex/spécial) + commandes
  app_modal.jl               infra modaux + guide/tutoriel/explain
  app_view.jl              ★ TK.view : chrome + arbre de panes + modal
  tui_pattern_editor.jl      playhead, zoom/shift/subdivise dans p"…"
  tui_leader_snippets.jl     Space-leader : templates + placeholders
  tui_autocomplete.jl        Tab : identifiants, ghost, commandes
  tui_editor_ops.jl          opérations texte pures
  tui_input_modes.jl         tap / piano / bpm
  tui_hints.jl               candidats de complétion
  tui_livedoc.jl             docs UGen/params, _GUIDE_LINES
  tui_scope.jl               écoute OSC des scopes, _APP_SCOPE_*
  modal_*.jl                 browse, mixer, lib, sculpt, wiki, snip, sccode

  ── Contenu / configuration ──
  session_config.jl, session_themes.jl, content_sccode.jl, content_wiki.jl
```

★ = à lire en premier pour comprendre la mécanique.

## Globals — qui écrit, qui lit

Ressac a une poignée de globals mutables au niveau du module.

```
_LIVE_SCHEDULER :: Ref{Union{Nothing,Scheduler}}    live_boot.jl
  Écrit par : start_live! / stop_live!
  Lu par : app_* (mute / panic / preview / kill voice…), live_api.jl,
           les callbacks de pattern sur le thread du scheduler.

_SAMPLE_REGISTRY / _INSTRUMENT_REGISTRY / _SYNTH_REGISTRY
                                                     plugin_registry.jl
  Écrits par : register_sample! / register_instrument! / register_synth!
           (plugin_handlers.jl au chargement ; :import-wav, :w, sculpt
           :w à chaud).
  Lus par : browse, complétion, ghost, snippets, event_to_osc.

_APP_SCOPE_TYPE, _APP_SCOPE_DATA, _APP_SPECTROGRAM_HISTORY   tui_scope.jl
  Écrits par : le listener OSC (/ressac/scope/*), déclenché par :scope.
  Lus par : _render_app_scope (app_scope.jl) à chaque frame.

_GHOST_USAGE                                         tui_autocomplete.jl
  Fréquence d'usage des complétions, persistée dans
  ~/.config/ressac/ghost_usage.json.

_LEADER_SNIPPETS / _LEADER_ACTIONS / _LEADER_LABELS  tui_leader_snippets.jl
  Constantes, lues par le dispatcher Space-leader et le footer.

_EVAL_MODE                                           live_api.jl
  Écrit par _eval_pattern_blocks! (:freeze) ; lu par _route_to_slot!.

_APP_MUTED_PATTERNS                                  app_patterns.jl
  Écrit par mute/solo ; lu par unmute et le mixer.

_PANE_MODE                                           workspace_keymap.jl
  État du mode pane (Ctrl-w). Les tests le remettent à false.

_EXPLORER_EXPORT_REQUEST / _EXPLORER_WAVEFORM_REQUEST / _EXPLORER_SCULPT_REQUEST
                                                     pane_synth_explorer.jl
  « Seams » : une pane poste une requête, app_input.jl la draine au
  prochain update! (une pane ne connaît pas RessacApp).
```

## Discipline de verrou (io_scheduler.jl)

Le scheduler détient le seul état synchronisé de Ressac : le dict de
patterns (`s.patterns`), le curseur de cycle (`s.last_end_cycles`), le
tempo (`s.cps`). Tous protégés par `s.lock`. Le chemin chaud `_step!` est
en deux phases :

1. **Snapshot** (verrou tenu, rapide) : draine les swaps de patterns en
   attente, copie `cps`, `t_start` et une copie superficielle du dict,
   avance `last_end_cycles`.
2. **Query + envoi** (verrou relâché) : pour chaque (slot, pattern),
   interroge les events de la fenêtre de lookahead, encode le bundle,
   envoie en UDP, accumule `last_fired_at` localement.

Une troisième prise de verrou minuscule réécrit `last_fired_at`. Les
mutateurs `set_pattern!` / `set_cps!` / `hush!` ne sont donc JAMAIS
bloqués par la complexité d'un pattern : l'eval ne fait pas bégayer
l'audio.

Si tu ajoutes de l'état au scheduler, garde la même discipline :
snapshot + avance + relâche avant tout travail long.

## Routage OSC

Deux chemins sortants, tous deux en UDP vers localhost:57120 :

```
/dirt/play       dispatch géré par SuperDirt. Samples et instruments
                 (tout ce qui doit passer par le calcul freq/sustain/
                 gain de SuperDirt + les effets globaux). Le nom du
                 synth est dans le champ `s`.

/ressac/play     contourne SuperDirt pour les synths utilisateur. Reprend
                 les defaults de params du SynthDef, donc un synth DSL
                 avec (freq=110, sustain=999) les garde vraiment.
                 event_to_osc choisit via `_is_user_synth(name)`.
```

Plus quelques canaux annexes :

```
/ressac/evalAndPlay      T dans la pane synth — envoie le source SC et
                         instancie une voix pour écoute.
/ressac/freeByName       mute d'un slot — libère les voix du SynthDef.
/ressac/panic            ! / :panic / :hush — s.freeAll côté SC.
/ressac/safety           bascule [LeakDC + HPF 10 Hz + Limiter 0.95].
/ressac/scope            abonne / désabonne l'analyse scope.
/dirt/loadSampleFolder   :import-wav — SC charge une nouvelle banque.
```

Entrant (UDP 57121, écouté par tui_scope.jl) :

```
/ressac/scope/amp        RMS par frame (60 Hz)
/ressac/scope/wave       buffer d'onde braille (60 Hz)
/ressac/scope/spectrum   magnitudes FFT (45 Hz)
/ressac/scope/{xy,goni,spectrogram,peak,pitch,onset,hist,corr}
/ressac/rms              RMS par orbit (taps Amplitude.kr)
/ressac/audio_in         RMS + bandes du bus d'entrée
/ressac/sc-meta-reply    version SC + nombre d'UGens (sc-autodiscover)
/ressac/sc-discovery-done
```

Ils atterrissent dans `_APP_SCOPE_DATA[]` (ou le `_APP_*` idoine) et
`view()` lit le global à chaque frame pour rendre le scope.

### Convention : les réponses SC → Ressac passent par `~ressacScopeAddr`

L'argument `addr` d'un callback OSCdef est le port éphémère SORTANT de
l'émetteur, pas le port d'écoute de Ressac. Répondre via
`addr.sendMsg(...)` jette le paquet sur un socket fermé : la session
semble saine jusqu'à ce qu'on attende une réponse qui n'arrive jamais.

Tout handler SC qui doit répondre utilise le global `~ressacScopeAddr`
(= `NetAddr("127.0.0.1", 57121)`, déclaré en tête de
`scripts/superdirt-startup.scd`). Voir `/ressac/rms`, `/ressac/audio_in`,
`/ressac/sc-meta` dans ce fichier pour le motif canonique.

Symptôme classique : un helper aller-retour Julia (`_sc_meta_roundtrip`,
`_handle_sc_discover`…) expire à chaque fois alors que le log SC montre
que le handler a tourné.

### Le listener démarre à la demande

`_ensure_app_scope_listener!()` ouvre le socket de réception et lance la
boucle de dispatch. Appelé à la demande : premier `:scope`, premier
`:audio-in`, premier handler sc-autodiscover. Tout code qui envoie un
paquet OSC en attendant une réponse doit l'appeler d'abord.

## Flux de rendu

`TK.view(m::RessacApp, f::TK.Frame)` (app_view.jl) tourne au fps
configuré (120 par défaut). Il :

1. découpe l'écran : status / workspace / strip / mode / livedoc /
   commande / footer / log ;
2. rend l'arbre de panes du workspace courant (`_render_tree!`, chaque
   `PaneImpl.render!` dans son rect, bordure accentuée sur le focus),
   puis les floats ;
3. peint les overlays de la pane patterns : flash d'eval, sélection
   visuelle, playhead, ghost ;
4. rend le chrome : status bar, strip de workspaces, strip de mode,
   livedoc, barre de commande (si active), footer, journal ;
5. rend le modal par-dessus tout, en laissant la dernière ligne à la
   barre de commande persistante.

Le playhead et le flash peignent APRÈS l'éditeur, donc par-dessus les
cellules sans rien savoir de l'état de l'éditeur.

## Routage d'une touche

`TK.update!(m, ::KeyEvent)` (app_input.jl), dans cet ordre :

1. barre de commande active → elle prend tout ;
2. `!` → panic, depuis n'importe où (sauf saisie de texte) ;
3. `Ctrl-1..9` workspaces, `Ctrl-w` mode pane (persistant) ;
4. modal ouvert → `_handle_modal_key!` ;
5. pane focalisée non-patterns → `PaneImpl.handle_key!` ;
6. flux patterns : leader Space, `?`, `e`/`E`, `m`, `K`, nudge, puis
   le CodeEditor Tachikoma.

Une pane ne connaît pas `RessacApp` : quand elle a besoin de l'app
(ouvrir un synth, un sculpt, exporter), elle poste une requête dans un
`Ref` global que `update!` draine (« seams », voir globals).

## Tâches de fond

```
boucle scheduler        io_scheduler.jl::start! — Threads.@spawn,
                        toutes les lookahead/2 s (25 ms par défaut).
moniteur stdin          Tachikoma — réveille la boucle de rendu.
rendu sculpt            pane_waveform.jl — Threads.@spawn par
                        version demandée, résultat déposé sous verrou.
sauvegarde ghost usage  écriture asynchrone de ghost_usage.json.
fetch sccode            synchrone (bloque le modal).
```

## Le registre de touches

Toutes les touches sont déclarées dans le registre (`src/keymap.jl`) :
`app_keymap.jl` pour l'app, chaque pane et chaque modal pour les
siennes. La barre de touches, l'aide `?`, le popup which-key et
`docs/wiki/04-keys.md` (généré par `scripts/gen_keys_wiki.jl`) en
dérivent. La refonte qui a mené là est décrite dans
`docs/journal/20260921_ui_ux_refonte_design.md`.
