# Sub-project 7 — Extension registry: docs + snippets as plugin-discoverable data

Status: approved 2026-05-27.

## Goal

Make `tui_docs.jl` shrink from ~1000 lines of inline `Vector{String}`
data into a generic registry whose contents come from plugin
directories on disk. The framework code keeps zero hard-coded doc or
starter content; everything ships as plugin data. The existing
"core" content (`n`, `gain`, `bd`, …, `techno-classic`, `dnb`) moves
into a dogfooded `plugins/core/` plugin, loaded first at boot. Third-
party plugins register their own docs / snippets via the same
mechanism — no special-casing.

The refactor also unifies the previously informal "starter" concept
and the not-yet-existing "snippet" concept into a single composable
entity, with a `mode` hint that controls default behavior but never
restricts how the user can invoke a given block.

## Non-goals

- No new TUI surface in this sub-project. `:doc X` and `:starter X`
  keep their current behavior (tooltips + buffer replace). The new
  `:s` command and snippet-editor UX land in a later sub-project.
- No templating / parameterization of snippets. `includes = [...]` is
  pure concatenation in topological order. Templating may be added
  later as a backwards-compatible field.
- No hot-reload of plugin content at runtime. Boot-time scan only;
  changes to MD/TOML files require restart. Hot reload is a separate
  sub-project if it ever becomes painful.
- No widget split-pane work. The schema *anticipates* the future
  refonte (`panes = [...]` field in snippets), but the field is
  parsed-and-ignored in this sub-project.
- SuperCollider UGen autodiscovery is a separate sub-project. It will
  consume the registry created here but not modify it.

## Architecture

Three abstractions, layered:

- **Plugin** — `plugin.toml` + content directories (`docs/`,
  `snippets/`). Pure data. No load-time code that touches the
  registry directly.
- **Registry** — module-level `Dict`s in `Ressac` core
  (`_DOCS::Dict{String,DocEntry}`,
  `_SNIPPETS::Dict{String,SnippetEntry}`). Single source of truth that
  the TUI reads from.
- **Loader** — extends the existing plugin loader. After running a
  plugin's Julia + SC files, the loader scans its content dirs (if
  declared), parses each file, and calls `register_doc!` /
  `register_snippet!`. One registration function per extension point.

Plugin = data. Loader = mechanism. Registry = state. The TUI never
opens MD/TOML files directly — it always queries the registry.

## File layout on disk

```
plugins/core/
├── plugin.toml
├── docs/
│   ├── n.md
│   ├── gain.md
│   ├── fast.md
│   ├── bd.md
│   └── ... (~110 files for non-reservoir, non-chaos entries)
└── snippets/
    ├── techno-classic.toml
    ├── techno-classic.jl
    ├── dnb.toml
    ├── dnb.jl
    └── ... (~12 starters from the existing dict)

plugins/reservoir/
├── plugin.toml            # extended with [docs] and [snippets]
├── reservoir.jl
├── *.scd
├── docs/
│   ├── Reservoir.adex.md
│   ├── Reservoir.pool_burst.md
│   ├── Reservoir.rate_voice.md
│   ├── drive_const.md
│   ├── ADEX_TONIC.md
│   └── ... (~33 entries that today live under "Reservoir plugin" in tui_docs.jl)
└── snippets/
    ├── reservoir-pop5.toml + .jl
    ├── reservoir-rate.toml + .jl
    ├── reservoir-explore.toml + .jl
    └── ... (~10 reservoir-prefixed starters)

plugins/chaos/
├── plugin.toml
├── ... existing ...
├── docs/
│   ├── lorenz.md
│   ├── henon.md
│   └── ... (~10 chaos-related docs)
└── snippets/
    ├── chaos-explore.toml + .jl
    └── ...
```

After migration, `src/tui_docs.jl` keeps only the *renderers* that
take a `DocEntry` / `SnippetEntry` and produce TUI output — roughly
50 lines instead of 1000+. The const dicts `_PARAM_DOCS`,
`_PARAM_EXAMPLES`, `_STARTER_PACKS` are deleted outright.

## Manifest schema (plugin.toml)

Two new top-level sections, both optional:

```toml
[docs]
dir = "docs"        # path relative to plugin root; scanned for *.md
                    # recursively. Defaults to "docs" if omitted AND
                    # the directory exists. Set to "" or omit to
                    # explicitly contribute no docs.

[snippets]
dir = "snippets"    # scanned for *.toml; each TOML may reference a
                    # sidecar *.jl via content_file. Defaults to
                    # "snippets" similarly.
```

Backwards compatibility: plugins without these sections behave
exactly as today — they contribute no docs or snippets, but the rest
of their behavior (julia files, synthdefs, samples, banks) is
unchanged.

## File formats

### Doc — `docs/<name>.md` with frontmatter

```markdown
---
name: Reservoir.pool_burst
short: "Route IV — pool N neurons into K bins, gain accumulates with spike count."
tags: [reservoir, route]
kwargs: [bins, frames_per_cycle, layout, drive, gain_per_spike, max_gain, burst_dur, mapping]
examples:
  - "@d1 Reservoir.pool_burst(r; bins=8) |> gain(0.5)"
  - "@d1 Reservoir.pool_burst(r; bins=12, frames_per_cycle=16, layout=:scale) |> gain(0.4)"
---

# Reservoir.pool_burst

Route IV qui regroupe N neurones du réservoir en K bins fréquentiels.
Quand plusieurs neurones tombent dans le même bin pendant une frame,
le gain s'accumule (jusqu'à `max_gain`).

## Paramètres

- `bins` — nombre de bins (>0). 8 ≈ pentatonique sur une octave.
- `frames_per_cycle` — événements par cycle …
- …
```

Frontmatter is YAML between `---` fences. The `short` field is what
`:doc <name>` shows today (tooltip line). The body (everything after
the closing `---`) is unused by this sub-project but is loaded into
`DocEntry.body` so the future pane refonte can render it without
re-reading the file.

The `name` field in frontmatter is the canonical name; the filename
is just a hint and need not match (but should, by convention).

### Snippet — `snippets/<name>.toml` + sidecar `<name>.jl`

```toml
# snippets/reservoir-pop5.toml
name = "reservoir-pop5"
mode = "starter"                       # or "block" (default if omitted)
description = "5 populations interconnectées qui se répondent"
tags = ["reservoir", "polyphonic"]
requires_plugins = ["reservoir"]       # checked at apply time
content_file = "reservoir-pop5.jl"     # path relative to TOML
includes = ["common.boilerplate"]      # other snippets, by name, prepended
                                       # in declared order

# Hints for the future UI refonte (parsed-and-ignored in this sub-project):
panes = [
  { kind = "editor", role = "primary" },
  { kind = "scope", target = "reservoir-graph", role = "side" },
]
```

```julia
# snippets/reservoir-pop5.jl
cps!(0.5)

p_A = Reservoir.adex(N=12, params=Reservoir.ADEX_TONIC, dt=1.0, ...)
...
```

The sidecar `.jl` is plain Julia. The loader runs `Meta.parse` on it
once at boot to catch syntax errors *before* a user tries to apply
the snippet. Parse failure → warning + skip the snippet (don't crash
boot).

## Modes — hints, never restrictions

Two values for `mode`:

- **`"starter"`** — appears in `:starter <Tab>` completion. Default
  action: replace current buffer.
- **`"block"`** (default) — appears in `:s <Tab>` completion. Default
  action: insert at cursor.

Either command can invoke any snippet regardless of declared mode.
`:starter common.boilerplate` is a legal way to start a fresh
session from a small library snippet; `:s reservoir-pop5` lets the
user inject the whole pop5 example mid-buffer (and live with the
consequences). The user always has the last word.

This sub-project ships `:starter` (existing) — `:s` arrives in a
later sub-project. But the data model is already correct for both.

## Composition — `includes` is concatenation, not templating

Each snippet may declare `includes = [name1, name2, …]`. At load
time, after every plugin has finished registering, the loader does
one topological pass and computes for each snippet:

```
resolved_content =
    join((resolve(inc).resolved_content for inc in includes), "\n\n")
    * "\n\n"
    * own_content   # the sidecar .jl file's body
```

`resolved_content` is stored on the `SnippetEntry` and is what
`:starter X` / `:s X` apply. No templating, no parameters, no runtime
re-resolution: the value is referentially transparent.

`requires_plugins` of an entry is the **union** of its own
declaration and the `requires_plugins` of every snippet it
transitively includes. So a snippet that includes
`reservoir.boilerplate` (which requires the `reservoir` plugin)
automatically requires `reservoir` too.

### Resolution errors

- **Missing include** (name not registered) → warning at load,
  `resolved_content = own_content` (the snippet is still usable, just
  without that include's contribution).
- **Cycle detected** → warning at load, every snippet in the cycle
  gets `resolved_content = own_content` (cycle members usable
  individually but the cycle is broken).
- **Sidecar `content_file` missing or unreadable** → warning + skip
  the snippet entirely. Other snippets in the same plugin remain
  loadable.
- **Sidecar parses with syntax error** (`Meta.parse` returns an
  `:error` head) → warning + skip the snippet. Other snippets
  unaffected.

## Registry types and API

New file `src/extension_registry.jl`, included from `Ressac.jl`:

```julia
struct DocEntry
    name::String
    short::String
    tags::Vector{Symbol}
    kwargs::Vector{Symbol}
    examples::Vector{String}
    body::String          # raw MD body after frontmatter (may be "")
    plugin::String        # source plugin name (e.g. "core", "reservoir")
    path::String          # absolute path to the source file
end

struct SnippetEntry
    name::String
    mode::Symbol          # :starter or :block
    description::String
    tags::Vector{Symbol}
    requires_plugins::Vector{String}   # transitive union after resolution
    includes::Vector{String}           # raw declared includes (for debug)
    resolved_content::String           # final Julia source ready to apply
    panes::Vector{Any}                 # future UI hints, parsed but unused
    plugin::String
    path::String                       # path to the TOML manifest
end

const _DOCS     = Dict{String,DocEntry}()
const _SNIPPETS = Dict{String,SnippetEntry}()

function register_doc!(e::DocEntry)
    if haskey(_DOCS, e.name) && _DOCS[e.name].plugin != e.plugin
        @warn "doc '$(e.name)' shadowed by plugin '$(e.plugin)' " *
              "(previously from '$(_DOCS[e.name].plugin)')"
    end
    _DOCS[e.name] = e
    return e
end

function register_snippet!(e::SnippetEntry)
    if haskey(_SNIPPETS, e.name) && _SNIPPETS[e.name].plugin != e.plugin
        @warn "snippet '$(e.name)' shadowed by plugin '$(e.plugin)' " *
              "(previously from '$(_SNIPPETS[e.name].plugin)')"
    end
    _SNIPPETS[e.name] = e
    return e
end

# Called once by the plugin loader after every plugin has registered its
# snippets. Walks the include DAG, computes resolved_content for each
# entry, and REPLACES the dict slot with a new immutable struct whose
# resolved_content field is filled. Handles missing-include and cycle
# fallback per the policy in "Resolution errors" above.
function _resolve_snippet_includes!() end   # body specified in the plan

# Read-side
list_docs()     = sort!(collect(keys(_DOCS)))
list_snippets() = sort!(collect(keys(_SNIPPETS)))
list_starters() = sort!([k for (k, v) in _SNIPPETS if v.mode === :starter])
lookup_doc(name::AbstractString)     = get(_DOCS,     String(name), nothing)
lookup_snippet(name::AbstractString) = get(_SNIPPETS, String(name), nothing)
```

`SnippetEntry` is an immutable struct. When the resolution pass needs
to fill `resolved_content`, it constructs a fresh `SnippetEntry` with
the resolved value and writes it back to `_SNIPPETS[name]`. The
initial registration from the loader passes a `SnippetEntry` with
`resolved_content = ""` (placeholder); the resolution pass replaces
those placeholders with the real concatenated content.

Last-wins on name conflicts (warning emitted). This is intentional:
users may ship a personal plugin that overrides core docs/snippets
with preferred phrasing or local conventions.

## Boot flow

1. Ressac startup → existing `plugin_loader` scans `plugins/`.
2. **NEW**: plugins are sorted so that `core` loads first, then the
   rest alphabetically. (Today's order is also alphabetical;
   inserting `core` at the front is a one-line change.)
3. For each plugin in order:
   - Parse `plugin.toml` (existing).
   - Run `[julia] files` (existing).
   - Load `[synthdefs] files` (existing).
   - **NEW**: if `[docs]` declared (or default `docs/` dir present),
     glob `*.md`, parse frontmatter + body, build `DocEntry`, call
     `register_doc!`.
   - **NEW**: if `[snippets]` declared (or default `snippets/` dir
     present), glob `*.toml`, parse manifest, read sidecar `.jl`,
     validate with `Meta.parse`, build *raw* `SnippetEntry` (with
     unresolved content), call `register_snippet!`.
4. **NEW**: After every plugin has been loaded, the loader calls
   `_resolve_snippet_includes!()` once. That function does a single
   topological pass over `_SNIPPETS`, computes `resolved_content` for
   every snippet (cycle detection, missing-include handling as
   specified above), and replaces each dict entry with a fresh
   `SnippetEntry` whose `resolved_content` is populated.
5. TUI starts; reads `_DOCS` and `_SNIPPETS` for tab completion,
   `:doc`, `:starter`.

If any single content file fails to parse, the loader logs a
warning and skips that entry. Boot never aborts due to bad plugin
content.

## TUI bindings

Today, in `src/tui_app.jl` (rough sketch of the existing call
sites):

```julia
# completion + tooltip
if haskey(_PARAM_DOCS, name)
    docline = _PARAM_DOCS[name]
    examples = get(_PARAM_EXAMPLES, name, String[])
    …
end

# starter loader
elseif (m = match(r"^:starter\s+([\w-]+)\s*$", line)) !== nothing
    sname = m.captures[1]
    if haskey(_STARTER_PACKS, sname)
        lines = _STARTER_PACKS[sname]
        …
    end
end

# tab completion source
all_keys = collect(keys(_STARTER_PACKS))
```

After:

```julia
entry = Ressac.lookup_doc(name)
if entry !== nothing
    docline = entry.short
    examples = entry.examples
    …
end

elseif (m = match(r"^:starter\s+([\w.-]+)\s*$", line)) !== nothing
    sname = m.captures[1]
    snip = Ressac.lookup_snippet(sname)
    if snip !== nothing
        _check_requires_plugins(snip.requires_plugins) ||
            return _log("[ERROR] snippet '$sname' requires plugin(s): $(snip.requires_plugins)")
        lines = split(snip.resolved_content, '\n')
        …
    end
end

all_keys = Ressac.list_starters()
```

The regex picks up `.` so includes like `common.boilerplate` are
addressable; today's regex was `[\w-]+`.

## Migration — one-shot script + manual cut-over

A throwaway script `scripts/migrate_inline_to_plugins.jl` (kept in
git history, deleted after the merge) reads the current `_PARAM_DOCS`,
`_PARAM_EXAMPLES`, `_STARTER_PACKS` from a fresh REPL load of
`tui_docs.jl` and writes out the target file tree.

Routing rules:

- Doc names starting with `Reservoir.`, `drive_`, or `ADEX_` →
  `plugins/reservoir/docs/<name>.md`.
- Doc names starting with `Chaos.`, or matching the chaos UGen list
  (`lorenz`, `henon`, `logistic`, `standard_map`, `latoo`, `lincong`,
  `quad`, `fbsine`, `gbman`, `cusp`) → `plugins/chaos/docs/<name>.md`.
- Everything else → `plugins/core/docs/<name>.md`.
- Starter names starting with `reservoir-` → `plugins/reservoir/snippets/`.
- Starter names starting with `chaos-` → `plugins/chaos/snippets/`.
- Everything else → `plugins/core/snippets/`.

For each doc entry, frontmatter is filled with:
- `name` = the dict key
- `short` = the dict value
- `tags` = best-effort inference from the source prefix (e.g.
  `[reservoir, route]` for `Reservoir.spike_burst`); the script
  emits a tag list it can compute and an empty list otherwise — the
  PR can refine these manually
- `examples` = `_PARAM_EXAMPLES[name]` if present, else `[]`
- `kwargs` = best-effort parsed from the `short` line (looking for
  `kwargs: foo, bar, baz` substring); empty if it can't tell

Body is left empty. We're not generating prose docs during migration.

For each starter:
- The dict value (`Vector{String}`) is joined with `\n` to become the
  sidecar `.jl` content.
- `name` = dict key.
- `mode = "starter"`.
- `description` = first line of the starter if it's a `# …` comment;
  the script strips that comment and uses what's left as
  `description`, else `description = ""`.
- `tags` = best-effort inferred from name prefix.
- `requires_plugins` = `["reservoir"]` for `reservoir-*`,
  `["chaos"]` for `chaos-*`, else `[]`.
- `includes = []` (no automatic composition extraction in this PR).

After the script runs, the human:
1. Reviews generated files (spot-check a few from each plugin).
2. Updates `plugin.toml` for core, reservoir, chaos to declare
   `[docs] dir = "docs"` and `[snippets] dir = "snippets"`. The core
   plugin.toml is created from scratch since `plugins/core/` doesn't
   exist today.
3. Deletes `_PARAM_DOCS`, `_PARAM_EXAMPLES`, `_STARTER_PACKS` from
   `src/tui_docs.jl`. Switches the call sites in `src/tui_app.jl` and
   anywhere else to use `Ressac.lookup_doc`, `Ressac.lookup_snippet`,
   `Ressac.list_starters`.
4. Runs full test suite. The existing TUI tests for `:doc` /
   `:starter` should still pass without modification because the
   externally observable behavior is unchanged.

The migration PR is large in lines (~250 new files, ~1000 lines
deleted from `tui_docs.jl`) but low risk — almost all of it is
data → data conversion.

## Testing

**Existing tests** — all current TUI tests around `:doc` and
`:starter` (~30 tests) must stay green without modification.

**New unit tests** (`test/test_extension_registry.jl`):

- Parse frontmatter — valid YAML between `---` fences →
  `DocEntry` with correct fields. Missing `name` → warning + skip.
  Missing `short` → `short = ""` and the doc is still registered.
  Malformed YAML → warning + skip the file.
- Snippet TOML parse — valid manifest + valid sidecar → registered
  `SnippetEntry`. Sidecar missing → warning + skip. Sidecar with
  Julia syntax error → warning + skip.
- `register_doc!` last-wins — register the same name from two
  plugins, second registration overwrites; warning emitted.
- `register_snippet!` last-wins — same semantics.
- `list_starters()` filters by `mode === :starter` only.

**Composition tests** (same file):

- Two-snippet chain — `A` includes `B`. After resolve, `A.resolved_content`
  starts with `B`'s content, then `A`'s own content.
- Three-snippet diamond — `A` includes `B` and `C`, both include `D`.
  `D` appears once in `A.resolved_content`, in topological order.
- Missing include — `A` declares `includes = ["missing"]`. After
  resolve, `A.resolved_content == A.own_content`; warning emitted.
- Cycle — `A` includes `B` includes `A`. Both snippets'
  `resolved_content` falls back to their own content; warning per
  cycle, not per node.
- `requires_plugins` propagation — if `A` includes `B` and `B.requires_plugins
  = ["foo"]`, then resolved `A.requires_plugins` contains `"foo"`.

**Integration tests** (`test/test_extension_registry_integration.jl`):

- Fixture plugin with `docs/foo.md` + `snippets/bar.toml` + `bar.jl`
  → loader picks them up → `lookup_doc("foo")` and
  `lookup_snippet("bar")` return populated entries.
- Boot order — fixture plugins `aaa` and `core` both register a doc
  named `clash`. After boot, `_DOCS["clash"].plugin == "aaa"` (core
  loaded first, then `aaa` overwrote).

**Migration round-trip property** (one-shot, kept in tests for
defense in depth):

- For every entry name in the pre-migration `_PARAM_DOCS` dict
  (snapshot embedded in the test), `Ressac.lookup_doc(name)` after
  boot returns an entry with `short == old_value`.
- For every entry name in pre-migration `_STARTER_PACKS`,
  `Ressac.lookup_snippet(name).resolved_content` equals
  `join(old_value, "\n")`.

This catches accidental content loss during the script-driven
migration.

## Risks and mitigations

- **Risk**: A user has a personal config that mutates `_PARAM_DOCS`
  at runtime → silent break. **Mitigation**: grep before merge —
  this pattern does not exist anywhere in tree, and it was never
  documented as a supported extension point.
- **Risk**: Snippet sidecar parses fine but eval crashes at apply
  time because a plugin is not loaded. **Mitigation**:
  `requires_plugins` is checked at `:starter` invocation time;
  missing plugin yields a clear error message ("snippet 'X' requires
  plugin(s): Y") instead of a stacktrace.
- **Risk**: Boot performance regresses from reading ~200 small
  files. **Mitigation**: measure once after migration; if >100 ms
  total, profile. Native filesystem reads of small files are
  typically <0.5 ms each, so ~100 ms total is the realistic upper
  bound.
- **Risk**: Two third-party plugins register the same snippet name
  silently because the user is not watching warnings. **Mitigation**:
  on startup, after all registrations, log a one-line summary
  `loaded N docs, M snippets (K shadowed)`. The shadow count alerts
  the user to a potential issue without being noisy.
- **Risk**: Migration script generates a doc with broken examples
  because the source string contained Julia-specific characters that
  trip YAML. **Mitigation**: the script wraps every example in
  double-quoted YAML strings with proper escaping; the test suite's
  round-trip property catches any escaping errors.

## Open questions deferred

- **Doc body rendering** — the MD body is loaded into `DocEntry.body`
  but not rendered anywhere in this sub-project. The pane refonte
  sub-project will add `:doc <name> --pane` or auto-open behavior.
- **Snippet body editing UX** — `:s edit <name>` opens the sidecar
  `.jl` in an editor pane. Belongs to the UI refonte + `:s` command
  sub-project, not here.
- **Templating** — `includes` with args (Nix-style derivations with
  parameters). Will be a backwards-compatible schema addition if and
  when we see at least three concrete use cases.
- **Tag-based filtering** — `:starter --tag reservoir <Tab>` to
  narrow completion by tag. Easy to add later once tags are
  consistently populated; not necessary for the foundation.

## Acceptance criteria

Sub-project 7 is done when:

1. `plugins/core/`, `plugins/reservoir/docs/`, `plugins/reservoir/snippets/`,
   `plugins/chaos/docs/`, `plugins/chaos/snippets/` exist and are
   populated.
2. `src/tui_docs.jl` no longer contains `_PARAM_DOCS`,
   `_PARAM_EXAMPLES`, `_STARTER_PACKS`.
3. `src/extension_registry.jl` exists with the API specified above.
4. The plugin loader scans `[docs]` and `[snippets]` sections and
   populates the registry.
5. `:doc <name>` and `:starter <name>` produce the same TUI output
   they produce today for every name that existed before the
   refactor.
6. `Ressac.list_starters()` returns the same set of names as
   `keys(_STARTER_PACKS)` did before the refactor.
7. Full test suite passes (currently 1392 tests; should be 1392 +
   new registry tests).
8. Boot adds no more than 200 ms over the pre-refactor baseline.

**Measured post-migration (2026-05-28):** 198 ms total plugin load
(125 docs, 121 snippets, 8 plugins). Of which ~25 % is JIT
compilation — steady-state load is ~150 ms. Within budget.
