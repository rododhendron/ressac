# Architecture

A map of how a keystroke becomes audio, and which file owns what.
Useful if you're contributing, debugging a stuck pattern, or just
curious.

## The 30-second version

```
your keystroke
      ↓
Tachikoma terminal loop (~/.julia/packages/Tachikoma)
      ↓ KeyEvent
src/app.jl :: update!(m, evt)
      ↓ mutates m.editor / m.scheduler
src/scheduler.jl :: _step! (background task, every lookahead/2 s)
      ↓ query patterns, build OSC bundles
src/osc.jl :: encode → UDP datagram
      ↓
SuperCollider / SuperDirt (port 57120)
      ↓
your speakers
```

Everything in Ressac is in **one Julia module** named `Ressac`. There
are no plugin boundaries inside the codebase — files just `include`
each other. The directory layout matches concern, not visibility.

## File responsibilities

```
src/
  Ressac.jl              ★ module root: exports + load order
  app.jl                   the TUI — the big one (~5800 LOC). Tachikoma
                           Model + render + key dispatch + modals.
                           To be split into smaller modules; see the
                           ROADMAP section at the end of this file.
  tui.jl                   `live()` entry point, scheduler bootstrap.
  config.jl                RessacConfig + ressac.toml loader.
  themes.jl                custom themes (cyberpunk / solarpunk) +
                           Tachikoma built-ins routing.

  core.jl                ★ Pattern{T} + Event{T} type
  algebra.jl               binary ops (stack/cat/mask), broadcast lifts
  combinators.jl           every/fast/slow/rev/jux/off/degrade/…
  controls.jl              the |> chain operators (gain/lpf/pan/n/…)
                           and the SuperDirt param auto-helpers.

  scheduler.jl           ★ real-time scheduling loop. The hot path.
                           Holds the pattern dict + lookahead state.
                           See "lock discipline" below.
  osc.jl                   OSC encode/decode (no networking)
  osc_listen.jl            UDP listen socket + scope-data dispatch

  parse_minino.jl          mini-notation parser (the inside of p"…")

  live_api.jl              @d1..@d64 macros, hush_all!, cps!
  live_api_helpers.jl      helpers shared with the legacy LiveModel

  plugins.jl             ★ plugin loader + the three live registries:
                             _SAMPLE_REGISTRY :: Dict{Symbol,SampleEntry}
                             _INSTRUMENT_REGISTRY :: Dict{Symbol,InstrumentEntry}
                             _SYNTH_REGISTRY :: Dict{Symbol,SynthEntry}
  plugin_handlers.jl       [samples], [instruments], [synths], [julia]
                           handlers — each declares one [section] of
                           plugin.toml manifests.

  synth_dsl.jl             SynthDSL module — Julia → SC compile-time DSL
  synth_library.jl         built-in DSL synth recipes (kick, kickbrut,
                           subdrop, …, 909 kit)
  snippets.jl              the ~80 named snippet templates
                           (patterns + synth_dsl + synth_sc + reference)

  wiki.jl                  in-app wiki page loader (reads docs/wiki/*.md)

  tui_docs.jl              _PARAM_DOCS, _PARAM_EXAMPLES, _STARTER_PACKS
  tui_livedoc.jl           _SC_UGEN_DOCS, _SYNTH_GUIDE_LINES, livedoc widget
  tui_bindings.jl          _GUIDE_LINES + the legacy LiveModel dispatch
  tui_hints.jl             autocomplete candidates for the legacy TUI
  tui_buffer.jl, tui_overlay.jl, tui_search.jl, tui_eval.jl
                           remnants of the pre-Tachikoma TUI; some are
                           still used (tui_docs/tui_livedoc/tui_bindings)
                           and some are vestigial.
```

★ = file you read first if you want to understand the core
mechanics.

## Globals — who writes them, who reads

Ressac has a handful of module-level mutable globals. They're
documented one-by-one below so you can audit any of them.

```
_LIVE_SCHEDULER :: Ref{Union{Nothing,Scheduler}}    in tui.jl
  Writers: start_live! / stop_live!   (tui.jl)
  Readers: most of app.jl (mute / panic / preview / kill voice / …),
           live_api.jl (@d1..@d64), controls.jl indirectly via the
           pattern callbacks running on the scheduler thread.

_SAMPLE_REGISTRY      :: Dict{Symbol, SampleEntry}     in plugins.jl
_INSTRUMENT_REGISTRY  :: Dict{Symbol, InstrumentEntry} in plugins.jl
_SYNTH_REGISTRY       :: Dict{Symbol, SynthEntry}      in plugins.jl
  Writers: register_sample! / register_instrument! / register_synth!
           — called by plugin_handlers.jl at load time, and by
           _import_wav! / _save_session_app! / sccode-import for
           hot-add at runtime.
  Readers: app.jl browser, autocomplete, ghost suggestions,
           snippets picker, scheduler event_to_osc routing.

_APP_SCOPE_TYPE :: Ref{Symbol}                         in app.jl
_APP_SCOPE_DATA :: Ref{Vector{Float32}}                in app.jl
_APP_SPECTROGRAM_HISTORY :: Vector{Vector{Float32}}    in app.jl
  Writers: osc_listen.jl when an /ressac/scope/* message comes back
           from SC. Triggered on demand by the :scope command.
  Readers: _render_app_scope (per-frame, in view()).

_CURRENT_SCALE   :: Ref{Symbol}                        in controls.jl
  Writers: _scale_set      (`:scale <name>` ex-command)
  Readers: degree() control op for scale-aware note offsets.

_GHOST_USAGE     :: Dict{String, Dict{String, Int}}    in app.jl
  Writers: _ghost_bump! on Tab accept / explicit completion.
  Readers: _compute_ghost! to rank suggestions by usage frequency.
  Persisted to ~/.config/ressac/ghost_usage.json.

_LEADER_SNIPPETS / _LEADER_ACTIONS / _LEADER_LABELS    in app.jl
  Const Dicts — write-once at load, read by the leader dispatcher.

_EVAL_MODE       :: Ref{Tuple{Symbol,Int}}             in live_api.jl
  Writers: _eval_pattern_blocks! when entering ":freeze" mode.
  Readers: _route_to_slot! (the @d1..@d64 expansion target).

_APP_MUTED_PATTERNS :: Dict{Symbol, Pattern}           in app.jl
  Writers: _mute_pattern_slot! / _solo_pattern_slot!.
  Readers: _unmute_pattern_slot! / mixer modal.
```

## Lock discipline (scheduler.jl)

The scheduler holds the only synchronised state in Ressac — the
pattern dict (`s.patterns`), the cycle cursor (`s.last_end_cycles`),
the tempo (`s.cps`). All four are protected by `s.lock`. The hot
path `_step!` is split into two phases:

1. **Snapshot phase** (lock held, fast):
   - Drain pending pattern swaps
   - Copy `cps`, `t_start`, and a shallow copy of the patterns dict
   - Advance `last_end_cycles`

2. **Query + ship phase** (lock released):
   - For each (slot, pattern), query events in the lookahead window
   - Encode OSCBundle, ship over UDP
   - Accumulate `last_fired_at` updates locally

A tiny 3rd lock acquisition writes back `last_fired_at`. This means
`set_pattern!` / `set_cps!` / `hush!` mutators are NEVER blocked by
user pattern complexity — eval doesn't stutter the audio.

If you add new scheduler state, follow the same discipline: snapshot
+ advance + release before doing any long work.

## OSC routing

Two outgoing paths, both UDP to localhost:57120:

```
/dirt/play       SuperDirt-managed dispatch. Used for samples and
                 instruments (anything that should go through
                 SuperDirt's freq/sustain/gain calculator + global
                 effects). The synth name is in the `s` field.

/ressac/play     Bypasses SuperDirt for user-defined synths. Picks
                 up the SynthDef's own param defaults so a DSL synth
                 with `(freq=110, sustain=999)` actually keeps those
                 instead of being overridden. event_to_osc decides
                 between the two via `_is_user_synth(name)`.
```

Plus a handful of side-channels:

```
/ressac/evalAndPlay     T in the synth pane — sends SC source +
                         instantiates one voice for preview.
/ressac/freeByName       Mute on a slot — frees running voices of
                         the named SynthDef (drone-kill).
/ressac/panic            ! / :panic / :hush — s.freeAll on SC side.
/ressac/safety           [LeakDC + HPF 10Hz + Limiter 0.95] toggle.
/ressac/scope            Subscribe / unsubscribe scope analysis.
/dirt/loadSampleFolder   :import-wav — tells SC to load a new bank.
```

Incoming (UDP 57121, listened by osc_listen.jl):

```
/ressac/scope/amp        per-frame RMS (60 Hz)
/ressac/scope/wave       braille waveform sample buffer (60 Hz)
/ressac/scope/spectrum   FFT magnitudes (45 Hz)
/ressac/scope/{xy,goni,spectrogram,peak,pitch,onset,hist,corr}
```

These land in `_APP_SCOPE_DATA[]` and the per-frame `view()` reads
the global to render the scope pane.

## Render flow

`TK.view(m::RessacApp, f::TK.Frame)` runs at the configured fps
(default 120). It:

1. Layouts the screen into rows: status / body / livedoc / footer / log
2. Renders status bar (sections + cycle gradient + state badges)
3. Renders the patterns pane (and the synth pane if open) wrapped in
   focus-aware `TK.Block` borders
4. Renders the scope (if active)
5. Paints the eval-flash overlay (post-:e green pulse, 0.6 s fade)
6. Paints the playhead overlay (active token in :accent — cached per
   line hash so unchanged lines skip the regex)
7. Renders the ghost autocomplete suggestion
8. Livedoc row (the word under cursor → param doc)
9. Footer (mode chip + context-aware hint set)
10. Log pane (severity-stripe per line, scroll indicator)
11. Modal overlay (if any) — `_render_*_modal!` clears its inner
    rect then draws on top of everything else

The playhead and eval-flash overlays paint AFTER the editor renders,
so they layer on top of cell contents without needing to know about
the editor's state.

## Background tasks

```
Scheduler loop          src/scheduler.jl::start! — Threads.@spawn
                         iterates every lookahead/2 s (default 25ms).
Stdin monitor           ~/.julia/.../Tachikoma — wakes the render
                         loop on terminal input.
Ghost usage save        async write to ~/.config/ressac/ghost_usage.json
                         on app exit and periodically.
sccode HTTP fetch       sync (blocks the modal). #TODO move to async
                         so the UI stays responsive on slow networks.
```

## What's planned to change

The biggest pending refactor is splitting `app.jl` (5800 LOC) into
~5 cohesive modules:

```
modals.jl          render + key handlers for :browse / :lib / :sccode /
                   :snip / :wiki / :mixer / :guide / :tutorial
pattern_editor.jl  playhead, eval flash, zoom/shift/silence/subdivide,
                   _eval_pattern_blocks!, mute / unschedule
input_modes.jl     tap, piano, leader-snippet expansion
autocomplete.jl    ghost, Tab-cycle, ex-command autocomplete
editor_ops.jl      vim word motions, visual modes, `.` repeat,
                   nudge-number-under-cursor
```

Each will be `include`-d from `Ressac.jl` and refer to `RessacApp`
without a module boundary — the goal is locality, not encapsulation.
