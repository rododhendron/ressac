# Changelog

All notable changes to this project. Entries are grouped by the audit-driven
sprints that produced them. Dates are when the sprint shipped on `main`.

## [Unreleased]

### Added
- LICENSE (MIT) at repo root — referenced by README, was missing.
- CHANGELOG (this file).

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
