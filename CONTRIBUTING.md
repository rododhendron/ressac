# Contributing

Thanks for considering a contribution! This file is short — the
[architecture wiki page](docs/wiki/10-architecture.md) is where the
real "how it works" lives.

## Quick start

```bash
git clone https://github.com/<you>/ressac && cd ressac
# Pick the install script for your OS, e.g.:
bash install/install-debian.sh
just test                  # the whole suite, ~2 min
just live                  # start the TUI (needs `just audio` running)
```

## Filing an issue

A useful bug report has:

1. The exact command you ran (`:tap`, `Space E …`, etc.)
2. What you expected vs what happened
3. The relevant log line — `:copylogs` puts the whole buffer on your
   clipboard. Paste from there.
4. Your Julia version + OS

If audio doesn't play, walk through
[docs/wiki/12-troubleshooting.md](docs/wiki/12-troubleshooting.md) first.

## Proposing a change

Open an issue describing the user-facing change before writing code,
unless the change is small enough that the diff IS the explanation.
For larger features, a short design discussion in the issue saves
both sides time.

## Code style

This repo is organised around **local files with clear
responsibilities** rather than a tight module hierarchy. The
top-level rules:

- **One concern per file** — `modal_*.jl` per modal, `editor_pattern.jl`
  for the playhead + pattern ops, `app_tap_piano.jl` for tap+piano,
  `editor_autocomplete.jl` for completion, etc. When a file passes ~500 LOC,
  ask whether it has two concerns hiding inside.
- **No unnecessary abstractions** — three similar lines is better than
  a premature helper. Add structure when the same shape appears in
  three or more places.
- **Docstrings on every public function** — `_helper` underscored
  names ARE public to other parts of the codebase, so they get
  docstrings too. One paragraph max, explaining the *why*; the *what*
  is the function signature.
- **No comments narrating the obvious** — `# Sort the list` above a
  `sort!` call adds nothing. Comments earn their keep by explaining
  *why* a non-obvious choice was made.

## Testing

```bash
just test
```

runs the full suite. Every `test/test_*.jl` also runs on its own
(`julia --project=. test/test_scheduler.jl`): they all start with
`include("helpers.jl")`, which sandboxes the disk, stubs the network and
provides the shared helpers. When you add a function:

- A unit test that covers the happy path
- One that covers an edge case (empty input, malformed input, etc.)
- For algorithmic functions (anything that "decides" something —
  `_detect_tap_period` is the canonical example), pin down the
  expected behaviour with a regression test. The constants tuned over
  several iterations of user feedback live there too.

The `test/test_tap_detection.jl` file is the best template — short
testset blocks per behaviour, each tagged with the reason it exists.

## Commit messages

Conventional-commits style:

```
feat(area): short summary

Longer paragraph explaining the why. Reference the audit item,
issue number, or user feedback that triggered this change.

Co-Authored-By: ...
```

`area` is loose but useful: `feat(patterns)`, `fix(scheduler)`,
`refactor`, `docs(wiki)`, `perf(render)`, `test(tap)`, etc. The
git history reads as a narrative this way — much easier to scan
than `update stuff`.

## Adding a new feature

The mental flow that works in this codebase:

1. **Sketch the user-facing surface first.** What does the user type?
   What do they see in response? Write it down in the issue, then
   code to that.
2. **Find the right file.** New modal → `modal_<name>.jl`. New
   pattern op → `editor_pattern.jl`. New control → `core_controls.jl`. New
   combinator → `core_combinators.jl` (or `core_tidal.jl` for the Tidal
   vocabulary). New DSL UGen → `synth_dsl.jl`. New snippet or starter → a
   `.toml` + `.jl` pair under `plugins/core/snippets/`. Every exported
   name needs a fiche in `plugins/core/docs/` (a test checks it).
3. **Register dispatch if needed** — ex-commands in `app_commands.jl`
   (`_register_*!`), leader snippets in `editor_snippets.jl`, keys in
   `app_keymap.jl` or the pane's own `bind!` calls.
4. **Update the wiki** — at minimum the `02-patterns` or `06-modes`
   page if it's user-visible.
5. **Add a test.**
6. **`just test`** until green.

## Larger refactors

Look at the recent commits in `git log --oneline -20` — most of the
`refactor:` ones extract a cohesive block from a file that had grown too
large into its own file. The pattern that worked:

1. Identify a contiguous block of related functions.
2. Move them verbatim to `src/<area>.jl` (no rewrites).
3. Replace the block with `include("<area>.jl")` at the original
   location so load order stays identical.
4. Run `just test`. If green, commit. If not, the include is in the
   wrong place — Julia load order is the only thing that can break.

This pattern keeps the diff small per commit (1 file extracted at a
time) and the risk near zero.

## Where things live

Quick map:

```
src/
  Ressac.jl                include order + exports (the only file map)
  core_*.jl                Pattern{T}, mini-notation, combinators, controls, tuning
  io_osc.jl / io_scheduler.jl   OSC encoding · the real-time loop
  io_scope.jl              OSC listener (UDP 57121): scope, meters, SC replies
  live_boot.jl / live_api.jl    start_live!, live(), @dN, cps!
  plugin_*.jl / extension_registry.jl   plugins, docs and snippets registries
  synth_dsl.jl             Julia → SuperCollider DSL
  synth_library.jl         built-in synth recipes
  genome_*.jl, ga_*.jl     the GA explorer: genome, validity, render, export, prune
  wave_sculpt.jl           knobs and structural edits on a genome
  pane_*.jl                one file per pane kind (editor, log, doc, waveform, drone…)
  modal_*.jl               one file per modal (browser, mixer, palette…)
  workspace_*.jl           split tree, commands, resize, persistence, pane mode
  keymap.jl                the key registry: scopes, layers, mixins, help sections
  app_model.jl             RessacApp and its accessors
  app_layers.jl            the key stack (transient → modal → pane → mode → global)
  app_key_engines.jl       the key engines (typing, vim, leader, piano, tap…)
  app_input.jl             mouse, routing to the focused pane, request drains
  app_ex_registry.jl       ex-command tables, registration, dispatch, history
  app_commands.jl          the ex commands themselves
  app_livedoc.jl           :doc, K, the DOC pane that follows the cursor
  app_modes.jl             PLAY / DESIGN / EXPLORE: commands per mode
  app_keymap.jl            the app's bindings (global, editor, modes, leader…)
  app_view.jl              TK.view: chrome, tree, modal, hover
  app_*.jl (others)        one concern each: patterns, synth, drone, sculpt, scope…
  editor_*.jl              the text editor: pattern ops, snippets, autocomplete, vim ops, fuzzy
  content_*.jl             markdown, glossary, wiki pages, livedoc tables
  tk_*.jl                  Tachikoma helpers (scroll panes, pickers, patches)
scripts/                  live.jl, build_sysimage.jl, sc-setup.scd
test/                     one test_<area>.jl per area + helpers.jl (shared sandbox and helpers)
```

## License

By contributing you agree your work is released under the MIT License
(see [LICENSE](LICENSE)).
