# Changelog

All notable changes to this project. The first entries (May 2026) are grouped
by the sprints that produced them; later ones by month, summarised from the
commit history.

## [Unreleased] — audit of 2026-11-16

Everything below came out of a full audit (pattern engine, synthesis side,
TUI, plugins / tests / repository). `ROADMAP.md` lists each finding and its
status; a box is ticked only when the fix has a test.

### Changed — behaviour you may notice
- **All signals live in `[0, 1]`**, like Tidal's: `sine`, `cosine`, `tri`
  were bipolar, `saw` / `square` / `rand_pat` / `perlin` were not, and
  `range_pat` assumed bipolar for all of them. `range_pat` / `rangex` now map
  from `[0, 1]`; the chaos generators and the reservoir modulator are
  rescaled the same way (`raw = true` gives the state variable).
- **Splitting a pane splits that pane** (it shares its own room, like tmux);
  closing one gives its room back to its neighbour. Open-then-close restores
  the layout; nothing else in the tree moves.
- **A name declared by two plugins goes to the one loaded last**, with a
  warning — one rule for samples, instruments, synths, docs, snippets and
  scales (they used to disagree). `core` loads first so it can be overridden.
- Euclidean rhythms use Bjorklund's algorithm (Tidal's rotation: `(5,8)` is
  `x.xx.xx.`); a negative count inverts; a literal step count of 0 is refused
  when the line is evaluated.
- Random draws go through one mixed hash: sequences differ from before.
  They stay reproducible, and `seed = n` decorrelates two combinators
  (`degradeBy(0.5; seed = 1)`, `sometimes(rev; seed = 2)`).
- Mini-notation: `<a b>*2` advances through the alternation, `<a <b c>>`
  nests, `<a@3 b>` / `<a _ b>` hold a step over several cycles,
  `<a b, c d e>` stacks voices, `1e3` is a number, and a detached number is
  a step (`0 ! 3`, `0? 3`).
- `dw` on the last word of a line stops at the end of the line (vim's rule);
  `de` / `ye` work (`e` no longer evaluates the line while an operator is
  pending); `d$`, `c$`, `d0` exist; in visual mode `m` and `e` act on the
  whole selection; `/text` searches the buffer (`n` / `N`); `Ctrl-f` toggles
  floats as the help says.
- In DESIGN, `:w` saves the synth whichever pane has the focus; in PLAY,
  `e` / `E` / `m` act on the patterns text from any pane.

### Fixed — things that could cut the sound or close the app
- A pattern that throws no longer costs the other slots their window: the
  faulty slot is removed and announced once in the log.
- Changing tempo no longer re-fires what the lookahead already shipped;
  `cps` must be finite and at most 64 (`:cps Inf`, or the same over OSC, left
  the scheduler silent until restart); after a suspend the loop resumes at
  the present instead of shipping thousands of stale bundles.
- Mouse events and `view` are guarded like keys: an exception is logged, the
  session goes on (a wheel scroll over a line with an accent closed the app).
- `slot(n)` can refer to itself or loop through another slot without
  overflowing the stack; a `Pattern{Any}` of sounds or controls plays.
- Offline sclang renders have a real timeout and their scripts always exit.
- Registries read by the scheduler thread are locked; background threads
  hand log lines to the UI instead of pushing into its vector.
- `:pause`, `:tap`, `:piano` work whatever pane has the focus (`:pause` from
  the wiki froze the screen with no way out); typing `!`, `:` or `Ctrl-w` in
  a modal's search field is text, not PANIC.

### Fixed — pattern engine
- Events longer than a cycle were invisible outside the cycle of their
  onset: a control such as `lpf("<400 2000>/2")`, a mask, a patterned
  `fast`, `chop`, `ply`, `bend`, `rev` dropped everything in the cycles that
  followed. Patterns now answer a second question — what is *held* over a
  window (`_held`) — next to what *starts* in it.
- `every`, `lastOf`, `sometimesBy`, `chunk`, `whenmod`, `off` accept an `f`
  that changes the value type (`every(2, gain(0.5), p"bd")`) and build
  `f(p)` once.
- `stack(p)` with one element no longer returns a function inside
  `layer`, `timeCat`, `stut`…; `"bd:x" |> gain(1)` no longer throws.
- `walk` and `markov` no longer replay their chain from cycle 0 on every
  query.

### Fixed — synthesis
- The SuperCollider parser no longer guesses. An unknown identifier, an
  unplaced keyword argument or unread text make it refuse — with the reason
  shown to the player — instead of becoming a silent `0` that `:sculpt`,
  `:prune` and `:todsl` then wrote back into the synth. Arrays, `mul:` /
  `add:`, references, symbols and `nil` are kept.
- Operators are read left to right, as SuperCollider evaluates them;
  `chorus` and `phaser` were emitting SC that relied on precedence (with
  `mix = 0`, chorus was silence).
- `var x = expr;` in a hand-written SynthDef is read; `.range` of a unipolar
  UGen (`LFPulse`…) keeps its range; unknown methods are rendered as
  methods, never as invented classes (`Abs.ar`).
- A synth whose only `EnvGen` modulates a filter still frees its node at the
  end of each note. Numbers reach SC through one formatter (`1//3`, `π`,
  `Inf`). Synth names are identifiers.
- A `@synth` evaluated with T, or saved with `:w`, updates the registry
  entry the manifest declared: six `chao*` synths had no pitch routing.
- `:export` of a DSL synth recorded silence (it sent Julia source to sclang).

### Fixed — TUI
- Vim operators, visual mode, number nudging and pattern operations count in
  characters, like the cursor — accents no longer break or corrupt them.
- Every edit Ressac makes is undoable, one `u` each.
- `:layout load` reads the file aside and swaps only on success (a broken
  file used to wipe the current text and log « chargé »).
- Switching to DESIGN puts back what is missing around the existing panes
  instead of discarding them. A selection or a snippet's placeholders do not
  survive leaving their buffer.
- sccode.org requests and the measured part of `:prune` run in the
  background; `:vsplit <unknown>` says so.
- Transient scopes (pane mode, visual, tap, piano, placeholders) are real
  registry actions: what the help shows is what runs.

### Tests and repository
- The suite no longer writes into `~/.config/ressac` or the repository, never
  touches the network, and every `test_*.jl` runs on its own. The precompile
  workload runs sandboxed too: it used to overwrite the saved layout on every
  recompilation.
- Tachikoma is pinned to `=2.1.0` and its three patches are applied only on
  that version. `just live-fast` no longer runs a sysimage older than the
  source. `recordings/` is ignored.
- Removed the unreachable editor command mode and a dozen functions nothing
  called.

---

## October 2026 — modes and keyboard layers

### Added
- PLAY / DESIGN / EXPLORE as compartmented modes, workspaces rebuilt from
  scratch (`:design!`, `:reset`), `:todsl` (a SuperCollider SynthDef → DSL).
- English fiches, a 91-term glossary, mouse-hover bubbles; the graph tab of
  the DOC pane; pane resizing by keyboard and mouse, proportions saved.
- The DESIGN chapter of the tutorial; live view of what a pattern does to a
  held drone.

### Changed
- The keyboard is a stack of layers (transient → modal → pane → mode →
  global) resolved in one place; help and the keys wiki derive from the
  registry. Files renamed for what they are.

### Fixed
- A command or key that throws no longer takes the app down; a busy port
  57121 no longer makes boot wait two minutes.

## September 2026 — the UI/UX rework, Tidal coverage, the synth workspace

### Added
- A keymap registry as the single source of keys (help, key bar, which-key,
  wiki page); clickable chrome; UI in French.
- The Tidal vocabulary: full mini-notation (`/ @ . .. {} %`, patterned
  arguments), note names, chords, `arp`, about a hundred combinators, left
  structure by default for controls, transitions.
- Pattern library and variations; palette (`Ctrl-p`); sound browser grid;
  note visualiser; slot rack with meters; mixing helpers (`duck`, `avoid`,
  `band`, `fan`, `declash`); maths (laws, curves, sequences).
- Synth side: Elixir-style `|>` in `@synth`, named knobs, guided pruning
  (`:prune`), drones with live modulation, the fixed text | studio / doc
  workspace, a step-by-step tutorial pane.

### Changed
- `tui_app.jl` (6 134 lines) split into `app_*.jl`; log, modals, pickers and
  mixer moved onto Tachikoma widgets; the key pipeline named and ordered.

## June 2026 — microtonality, the genetic explorer, sculpt

### Added
- Scales and microtonal tuning (`note`, `scale`, `:tuning`, a tuning pane,
  plugin `[[scales]]`).
- The genome: a DAG of UGens with validation, repair, mutation, crossover,
  rendering to a safe SynthDef and to the DSL; the EXPLORE pane (ratings,
  strategies, lineage, roles, offline acoustic analysis through headless
  sclang, waveform viewer, explainer).
- Sculpt: knobs on a sound's graph, structural edits, a studio.

## Late May 2026 — registries, SC autodiscovery, split panes

### Added
- Docs and snippets as plugin-contributed registries (`[docs]`,
  `[snippets]`), `core` as a plugin.
- SuperCollider UGen autodiscovery at boot (cached, with generated fiches).
- The pane system: layout tree, workspaces, split / close / navigate, pane
  mode, floats, layout autosave and named layouts; an autonomous command bar.

---

## Sprint 7 — final extractions + external MIDI bridge (2026-05-25)

### Added
- **External OSC trigger API**: `/ressac/trigger s:<name> [k v …]` fires
  through SuperDirt; `/ressac/set s:cps v:<n>` mutates tempo. MIDI
  controllers, TouchOSC, hardware sequencers, Max patches, even other
  Julia processes can drive Ressac without a Julia MIDI dependency.
- Wiki page `13-external-midi.md` with a 6-line SuperCollider snippet
  that bridges MIDI → /ressac/trigger.

### Changed
- Wiki `03-synth-dsl` + `06-modes` refreshed for chorus/flanger/phaser,
  909 kit, tap-loop default, Space-leader, `:mixer`.

### Refactored
- `editor_ops.jl` (477 LOC) — vim word motions, visual modes (line +
  char), `.` repeat, slot-tracking for dd-unschedules.
- `autocomplete.jl` (501 LOC) — Tab cycle, ghost suggestion + usage
  persistence, ex-command completion.

After sprint 7: `app.jl` 4016 → 3540 LOC (peak was ~6500, so −46%).

---

## Sprint 6 — packaging + per-OS install (2026-05-25)

### Added
- README rewrite — Why / Install (Nix + standalone) / First five minutes /
  Featured commands / Wiki index / Dev recipes.
- PackageCompiler sysimage build: `just sysimage` (one-time ~3 min) +
  `just live-fast` (~1s cold start vs ~12s).
- `scripts/build_sysimage.jl` + `scripts/precompile_workload.jl`.
- Per-OS one-shot install scripts:
  `install-debian.sh` · `install-fedora.sh` · `install-arch.sh` ·
  `install-macos.sh` · `install-windows.ps1` · `install-nixos.md`.
- Shared `install/sc-setup.scd` — installs SuperDirt / Dirt-Samples /
  Vowel Quarks. All scripts idempotent.

### Refactored
- `pattern_editor.jl` (405 LOC) — playhead + eval flash + zoom/shift/silence/subdivide.
- `leader_snippets.jl` (194 LOC).
- `input_modes.jl` (460 LOC) — tap + piano + period detection.

### Fixed
- Sysimage build script parse error (`@__DIR__ * "/.."` → `joinpath`).

---

## Sprint 5 — UX polish + wiki expansion (2026-05-25)

### Added
- Eval errors are now humanised: `MethodError` / `UndefVarError` / etc.
  become actionable hints ("unknown name `foo` — :browse to see loaded
  sounds, or :doc foo").
- `:mixer` modal: `+/-/*//` nudge gain on slot under cursor (rewrites
  the buffer + re-evals the slot, live).
- Wiki page `11-tidal-migration` — crib sheet for TidalCycles users.
- Wiki page `12-troubleshooting` — silent SC, OSC port, error catalogue.

### Changed
- Wiki `01-intro`, `02-patterns`, `04-keys` refreshed for tutorial,
  leader, mixer, mini-notation extensions, Tidal combinators.

---

## Sprint 4 — Tidal-parity + DAW basics (2026-05-25)

### Added
- Mini-notation extensions: `?` (degrade), `_` (extend previous slot),
  `(k,n,rot)` (Euclidean rotation).
- 5 new genre starter packs: dubstep, amapiano, jungle, idm, hardcore.
- DSL FX wrappers: `chorus`, `flanger`, `phaser`, `grain_buf`, `warp1`.

### Refactored
- Modal extractions from `app.jl`:
  `modal_wiki.jl`, `modal_mixer.jl`, `modal_synth_library.jl`,
  `modal_browser.jl`, `modal_snippets.jl`.

---

## Sprint 3 — maintainability foundations (2026-05-25)

### Added
- 10 new tests pinning down `_detect_tap_period` heuristics.
- Wiki page `10-architecture` — file responsibilities, globals
  read/write inventory, scheduler lock discipline, OSC routing.

### Refactored
- `modal_sccode.jl` extracted — first proven include-pattern split.
- Sccode loaders: 3 copies of fetch+save+register collapsed to 1
  helper (`_sccode_import!`).

---

## Sprint 2 — DAW-parity feature batch (2026-05-25)

### Added
- 11 Tidal-style combinators: `jux`, `juxBy`, `off`, `degrade`,
  `degradeBy`, `sometimes`, `often`, `rarely`, `palindrome`, `iter`,
  `chunk`. All exported + curried for pipe use.
- 909-style drum kit (8 synths under `tr909` category): k909, s909,
  hh909, oh909, cp909, rim909, ride909, tom909.
- `compress` / `compressThreshold` / `compressRatio` SuperDirt controls.
- `pump(steps, depth)` — sidechain-style gain ducking via per-cycle
  gain pattern.
- `:import-wav <path> [as <name>]` — copy audio into
  `plugins/user-samples/<name>/` and register live, no plugin.toml
  needed.
- Wiki page `09-samples` — adding your own audio.
- `:mixer` modal (read-only at this point — gain edit came in sprint 5).

---

## Sprint 1 — bug + perf fixes (2026-05-24)

### Fixed
- StringIndexError in `_accept_ghost!` + `_pat_replace_body!` when
  the buffer contained multi-byte UTF-8 chars (¹ ° ▓ …). Char-based
  splitter `_char_split` is the new common helper.
- Scheduler lock contention: `_step!` was holding the lock during all
  pattern queries + OSC encode. Split into snapshot phase (lock held,
  fast) + query/encode phase (unlocked). Eval no longer stutters audio.
- Playhead overlay was re-running regex + body split per visible line
  per frame (~5000 allocs/sec). Now cached per line-content hash;
  microbench shows 5× faster, ~2.6× less GC pressure.

### Added
- Onboarding helpers: 7-line commented starter buffer, `?` shortcut
  → `:guide`, `:tutorial` modal with 5 cards.

---

## Sprint 0 — pre-audit baseline (history before 2026-05-24)

The full feature set that existed before the audit-driven sprints:
patterns + mini-notation + pipe combinators + Synth DSL + Tachikoma
TUI + scheduler + OSC + SuperDirt integration + scope + sccode browser
+ tap mode + piano mode + Vim modal editor + ghost autocomplete +
plugins + 8 wiki pages. See git log up to `2b8bd48` for the granular
history.

---

### How this changelog is maintained

When a sprint ships, drop its summary at the top under a new `## Sprint N`
heading. Use `### Added` / `### Changed` / `### Fixed` / `### Refactored`
subheadings. Keep entries one-line where possible. Defer to commit
messages for technical detail — the changelog is the human story.
