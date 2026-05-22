# Sample bank plugins — Design

> Second of six sub-projects under the "sound design / sound library" track.
> Builds on the plugin architecture (sub-project 1) to turn `[samples]` from
> a "load these folders into SuperDirt" stub into a curatable bank format:
> short-name aliases, multi-bank namespaces, per-sample metadata, and live
> discoverability/preview commands.

## 1. Goal

Make the sample workflow first-class:
- **Curate** at design time: a plugin author writes a TOML that maps short
  memorable names to files or folders, with optional metadata.
- **Inspect** at session time: live commands list what's loaded, show
  metadata, and audition a sample without inserting it into a pattern.
- **Play** at performance time: short names are usable in patterns
  (`@d1 p"kicky snare hh sn"`) exactly like SuperDirt's default `bd:N`
  syntax.

The four pain points addressed (all in one sub-project):
- **(a) Aliasing** — `kicky` → some buried WAV
- **(b) Discoverability** — `:samples`, `K` (preview-under-cursor)
- **(c) Multi-bank** — one plugin ships many named banks
- **(d) Metadata** — BPM/key/tags stored, queryable; powers smart
  selection in later sub-projects

## 2. UX walkthrough

A plugin author drops this:

```
plugins/funkit/
├── plugin.toml
├── samples/
│   ├── bd/*.wav            # default load — names from folder
│   └── sn/*.wav
└── curated/
    ├── kicks/heavy_v3.wav
    └── snares/*.wav
```

```toml
# plugins/funkit/plugin.toml
name        = "funkit"
version     = "0.1.0"
description = "kicks, snares + a curated 808 collection"

[samples]
roots = ["./samples"]

[samples.bank]
kicky  = "./curated/kicks/heavy_v3.wav"
snares = "./curated/snares"

[samples.metadata.kicky]
bpm  = 120
key  = "C"
tags = ["heavy", "subby"]

[samples.metadata.snares]
tags = ["acoustic"]
```

Live session:

```
> @d1 p"bd hh kicky sn"          # `kicky` from funkit, `bd`/`hh`/`sn` from defaults
[INFO] eval d1 ⇒ nothing

:samples<Enter>
─── funkit ──────────────────────────
  kicky                 1 variant   [heavy, subby]  120 BPM
  snares                7 variants  [acoustic]
─── (Dirt-Samples) ──────────────────
  bd                   12 variants
  hh                    8 variants
  …
```

Cursor on `kicky` in the buffer, press `K`:

```
[INFO] preview kicky:0
```

Sample plays once via a one-shot `/dirt/play s "kicky"`, no pattern
installed.

## 3. Manifest format

The `[samples]` section grows three optional siblings:

### `[samples].roots` (existing)

Unchanged from sub-project 1. Folders to load with SuperDirt's default
convention (subdir name → bank name).

### `[samples.bank]` (new) — unified bank map

A TOML table mapping a **bank name** (string) to a **path** (string,
relative to the plugin dir or absolute). The path can be:

- a **file**: registers a single-variant bank, accessible as `<name>:0`
  in patterns.
- a **directory**: registers a multi-variant bank, sorted alphabetically;
  `<name>:0` is the first file, `<name>:1` the second, etc.

```toml
[samples.bank]
kicky  = "./curated/kicks/heavy_v3.wav"   # single file
snares = "./curated/snares"                # directory
```

This subsumes both aliasing and multi-bank namespacing. Naming conflicts
between banks across plugins log `[WARN] sample bank '<name>' shadowed
by plugin '<X>' (already loaded from '<Y>')` and the second one is
skipped.

### `[samples.metadata.<bank>]` (new) — per-bank metadata

Optional. Any key/value pairs the plugin author wants to associate with
a bank. Conventional keys:

- `bpm` (Number)
- `key` (String, e.g. "C", "F#m")
- `tags` (Array of strings)
- `length_ms` (Number) — for individual file banks
- `description` (String)

The loader stores them verbatim. Future sub-projects (smart selection,
in-app sound design) will query them; for v2 they're just inspectable
via the registry.

```toml
[samples.metadata.kicky]
bpm  = 120
key  = "C"
tags = ["heavy", "subby"]
```

## 4. Julia-side registry

A module-level registry tracks every bank loaded across all plugins.
Living in `src/plugins.jl` (it's plugin-related but accessed from the
sample handler and TUI commands).

```julia
struct SampleEntry
    name::Symbol                # :kicky
    plugin::String              # "funkit"
    bank_path::String           # /abs/path/to/file_or_dir
    variants::Vector{String}    # [/abs/.../heavy_v3.wav]
    metadata::Dict{String,Any}  # { "bpm" => 120, "tags" => [...] }
end

const _SAMPLE_REGISTRY = Dict{Symbol, SampleEntry}()

# Public API
sample_info(name::Symbol)               # → Union{SampleEntry, Nothing}
list_samples(pattern::Regex = r"")      # → Vector{SampleEntry}, sorted by plugin then name
register_sample!(entry::SampleEntry)    # used by handlers; warns on shadow
```

The `[samples].roots` path keeps using SuperDirt's directory walk, but
ALSO populates the registry: after sending `/dirt/loadSampleFolder`, the
handler scans the root locally, identifies each subfolder, and creates a
`SampleEntry` per subfolder. This way `:samples` shows everything,
including the "default" banks from `roots`.

`[samples.bank]` entries are registered individually: each (name, path)
pair becomes one `SampleEntry`. The handler also sends a new
`/dirt/registerSample` OSC (see §5).

## 5. SuperDirt-side: `/dirt/registerSample`

A new OSCdef in `scripts/superdirt-startup.scd`:

```supercollider
OSCdef(\ressacRegisterSample, { |msg|
    var name = msg[1].asString.asSymbol;
    var path = msg[2].asString;
    if(File.exists(path)) {
        if(File.type(path) == \directory) {
            // Multi-variant bank: walk dir, build Buffer per file.
            ~dirt.loadSoundFiles(path ++ "/*", appendToExisting: false);
            // Hack: loadSoundFiles indexes by parent-dir name, which is
            // wrong for our use case. We need to populate
            // ~dirt.soundLibrary.buffers[name] directly. See impl notes.
        } {
            // Single-file bank: register one Buffer under `name`.
            var buf = Buffer.read(~dirt.server, path);
            ~dirt.soundLibrary.addBuffer(name, buf);
        };
    } {
        ("[ressac] registerSample missing path: " ++ path).warn;
    };
}, '/dirt/registerSample');
```

The exact SC code may need adjustment — SuperDirt's `soundLibrary` API
uses `addBuffer`/`buffers` and exact semantics need verification. The
plan in implementation will pin this down by reading SuperDirt source.

**OSC arg format**: `/dirt/registerSample <name:String> <path:String>`.

## 6. TUI bindings

### `K` in normal mode — preview-under-cursor

1. Extract the word under the cursor (regex `[\w:]+`).
2. Look it up in `_SAMPLE_REGISTRY`. If the word has the form `name:N`,
   strip the `:N` and look up `name`.
3. If found: send `/dirt/play s "<name>" n N` (where N defaults to 0)
   via the active scheduler's OSC client. One-shot, no pattern install.
4. Log `[INFO] preview <name>:N` to the model logs.
5. If not found: log `[WARN] no sample '<word>' loaded`.

Preview bypasses the scheduler's pattern queue entirely — the OSC bundle
has time tag 0 (immediate), shipping the moment `K` is pressed.

### `:samples` command (extends the ex-command parser)

- `:samples`                 — list all loaded samples grouped by plugin
- `:samples <glob>`          — filter by glob (`bd*`, `*y`, `kic?y`)
- `:samples <name>`          — show full metadata for one bank

Output goes to the model logs (so it's visible in the bottom pane of the
TUI). For a long list, last-line wins per `_MAX_LOGS` truncation — but
each result fits on one line so up to ~200 entries fit naturally.

Rendering format:

```
─── <plugin> ──────────────────────────
  <name>  <N variants>  [tag1, tag2]  <bpm> BPM
```

`bpm`/tags shown only when present in metadata.

## 7. File layout

| File | Status | Responsibility |
|---|---|---|
| `src/plugins.jl` | extend | Add `SampleEntry` struct, `_SAMPLE_REGISTRY`, `sample_info`, `list_samples`, `register_sample!`. |
| `src/plugin_handlers.jl` | extend | `_handle_samples` now reads `[samples.bank]` and `[samples.metadata]`, registers entries, sends new OSC. |
| `src/tui_bindings.jl` | extend | `K` in normal mode → preview helper. `:samples …` command in `_execute_ex_command!`. |
| `scripts/superdirt-startup.scd` | extend | New `OSCdef(\ressacRegisterSample)`. |
| `src/Ressac.jl` | extend | Export `sample_info`, `list_samples`. |
| `test/test_plugin_handlers.jl` | extend | Tests for `[samples.bank]` registration, metadata storage, OSC packets shipped. |
| `test/test_tui_bindings.jl` | extend | Test for `K` preview path (with MockOSCClient). |
| `test/fixtures/plugins/withbanks/` | **new** | Fixture plugin with multiple banks + metadata. |
| `docs/cheatsheet.md` | extend | Update "Plugins" section with `[samples.bank]` + the `K`/`:samples` workflow. |

## 8. Test strategy

End-to-end coverage with `MockOSCClient` injection (same pattern as
sub-project 1):

- Manifest with `[samples.bank]` populates `_SAMPLE_REGISTRY` with one
  entry per bank entry.
- File-path banks produce `SampleEntry` with `variants = [<that file>]`.
- Directory-path banks produce `SampleEntry` with sorted variants.
- Metadata from `[samples.metadata.<bank>]` is attached to the
  corresponding `SampleEntry`.
- Sending OSC: `/dirt/registerSample <name> <abs_path>` is shipped once
  per bank entry, plus `/dirt/loadSampleFolder` per root (back-compat).
- Bank-name conflict across plugins: second registration logs warning,
  first wins.
- `list_samples()` returns sorted output; pattern filter works.
- `sample_info(:nope)` returns `nothing`.
- TUI `K` keystroke: cursor on `kicky` → mock OSC client receives
  `/dirt/play s "kicky"`. Cursor on `kicky:2` → `/dirt/play s "kicky" n 2`.
- TUI `:samples bd*` writes the filtered list to model logs.

## 9. Out of scope (deferred)

- **Smart selection** by metadata (`random_kick(bpm=120)`) — needs a
  query DSL. Sub-project 4 (instrument presets) territory.
- **Editing the manifest from the TUI** — sub-project 6 sound design.
- **Auto-tagging** via BPM/key detection on load — needs audio analysis.
- **Sample chopping / pitch shifting** in-app — sub-project 6.
- **Watch-and-reload** on manifest changes — needs a file watcher.
- **Hot-reload of plugins** without restarting Ressac.
- **Sample folder layout conventions enforcement** (e.g. require
  `<plugin>/samples/*` to exist) — plugin authors are free to organize
  however.
- **Multi-channel / spatialized sample mapping** — defer to when the
  user actually needs it.

## 10. Migration / compatibility

- Plugins from sub-project 1 with only `[samples].roots` continue to
  work unchanged. They get auto-populated registry entries from the
  filesystem scan after `/dirt/loadSampleFolder`.
- The existing `_handle_samples` is extended in place. No new section
  handler name (no `[samples.bank]` as a top-level section — it's
  nested under `[samples]` like `roots`).
- `MockOSCClient` interface unchanged.
- The `Pattern` / scheduler layer is unchanged: short bank names just
  produce `Event{Symbol}` with `value = :kicky`, and `event_to_osc`
  already handles `Symbol` → `/dirt/play s "<name>"`.

## 11. Why this scope works in one sub-project

- All four features (aliasing, discoverability, multi-bank, metadata)
  share the same data structure (`SampleEntry`) and the same code path
  (the `[samples]` handler). Splitting them into separate sub-projects
  would create artificial dependencies.
- The total new surface is modest: one struct, ~5 helpers, one OSC
  responder, two TUI bindings, one cheatsheet section.
- Each feature is testable in isolation: aliasing test loads a fixture
  with `[samples.bank] x = "..."` and asserts on registry; metadata
  test asserts `sample_info(:kicky).metadata["bpm"] == 120`; preview
  test triggers `K` on a `MockOSCClient`-backed scheduler.
