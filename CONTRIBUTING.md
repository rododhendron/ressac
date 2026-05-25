# Contributing

Thanks for considering a contribution! This file is short — the
[architecture wiki page](docs/wiki/10-architecture.md) is where the
real "how it works" lives.

## Quick start

```bash
git clone https://github.com/<you>/ressac && cd ressac
# Pick the install script for your OS, e.g.:
bash install/install-debian.sh
just test                  # 629 tests, ~10s
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

- **One concern per file** — `modal_*.jl` per modal, `pattern_editor.jl`
  for the playhead + pattern ops, `input_modes.jl` for tap+piano,
  `autocomplete.jl` for completion, etc. When a file passes ~500 LOC,
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

runs the full suite (629 tests at last count). When you add a function:

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
   pattern op → `pattern_editor.jl`. New control → `controls.jl`. New
   combinator → `combinators.jl`. New DSL UGen → `synth_dsl.jl`. New
   snippet → `snippets.jl`. New starter → `tui_docs.jl::_STARTER_PACKS`.
3. **Register dispatch if needed** — ex-commands in `app.jl::_register_*!`,
   leader snippets in `leader_snippets.jl::_LEADER_SNIPPETS`, key
   handlers in `app.jl::update!`.
4. **Update the wiki** — at minimum the `02-patterns` or `06-modes`
   page if it's user-visible.
5. **Add a test.**
6. **`just test`** until green.

## Larger refactors

Look at the recent commits in `git log --oneline -20` — most of the
`refactor:` ones extract a cohesive block from `app.jl` into its own
file. The pattern that worked:

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
  app.jl                 main loop + dispatch + render orchestration
  scheduler.jl           real-time scheduling loop (the hot path)
  core.jl                Pattern{T} + Event{T} types
  combinators.jl         pure, fast, slow, jux, off, every, …
  algebra.jl             stack, cat, mask
  controls.jl            gain, lpf, pan, n, pump, …
  mininotation.jl        the p"…" parser
  synth_dsl.jl           Julia → SuperCollider DSL
  synth_library.jl       built-in synth recipes
  snippets.jl            named multi-line snippet templates
  modal_*.jl             one file per modal (browser / mixer / …)
  pattern_editor.jl      playhead, zoom/shift/silence/subdivide
  input_modes.jl         tap + piano
  leader_snippets.jl     Space-leader expansion + placeholder nav
  autocomplete.jl        Tab + ghost + ex-command completion
  editor_ops.jl          vim word motions + visual + . repeat
  osc.jl                 OSC encode/decode (no networking)
  plugins.jl             plugin loader + the three live registries
  tui_scope.jl           scope listener (UDP 57121) + external trigger

docs/wiki/                in-app docs (browsable via :wiki)
install/                  per-OS one-shot installer scripts
scripts/                  live.jl, build_sysimage.jl, sc-setup.scd
test/                     629 tests
```

## License

By contributing you agree your work is released under the MIT License
(see [LICENSE](LICENSE)).
