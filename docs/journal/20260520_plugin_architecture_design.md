# Plugin architecture — Design

> First of six sub-projects under the "sound design / sound library" track.
> Defines the extensible plugin foundation that the other five sub-projects
> (sample banks, SynthDef bundles, instrument presets, live recording,
> in-app sound design) will build on. Spec covers the loader infrastructure
> and the two foundational section handlers — `[samples]` and
> `[synthdefs]`. Instruments, recording, and the rest are deliberately
> deferred to their own sub-projects.

## 1. Goal

Make Ressac extensible by third parties without touching the core. A
"plugin" is a directory of files (manifest TOML + samples + SC code + optional
Julia hooks) that Ressac discovers on a search path at session start. The
loader is **dumb on purpose** — it knows how to find plugins and dispatch
each manifest section to a handler, but doesn't know what a "sample" or a
"synthdef" is. Built-in section handlers add those meanings. Third-party
plugins can register new section handlers via the same public API.

End state: users `git clone someone/funkit` into `./plugins/funkit/`,
restart Ressac, and the new sounds are immediately playable in patterns.
The plugin author writes one TOML file and drops their WAVs in.

## 2. UX walkthrough

```
$ tree plugins/
plugins/
└── funkit/
    ├── plugin.toml
    ├── samples/
    │   ├── kick.wav
    │   ├── snare1.wav
    │   └── snare2.wav
    └── synths/
        └── bassline.scd

$ cat plugins/funkit/plugin.toml
name        = "funkit"
version     = "0.1.0"
description = "personal kick + snare collection + a bassline synth"

[samples]
roots = ["./samples"]

[synthdefs]
files = ["./synths/bassline.scd"]
```

```
$ just live
[INFO] loaded plugin: funkit 0.1.0  (samples: 3, synthdefs: 1)

In TUI:
> @d1 p"kick snare1 kick snare2"  |> fast(2)
> @d2 p"bassline*4"
```

## 3. Search path

Ressac resolves plugins via this ordered list (first hit wins per plugin name):

1. `./plugins/<name>/`         — current working directory at session start
2. `~/.config/ressac/plugins/<name>/`   — user-wide
3. `$RESSAC_PLUGIN_PATH` (colon-separated)  — escape hatch / Nix store

A plugin is identified by its directory's `plugin.toml`. If a directory
on the path lacks `plugin.toml`, it is silently skipped (so users can
keep notes or unfinished work alongside loadable plugins).

Conflicts: if two paths supply a `funkit` plugin, the first one wins and
a `[WARN] plugin 'funkit' shadowed by <path>` is logged.

## 4. Manifest format

`plugin.toml` is a TOML file. Required top-level keys: `name` (string,
must match the directory name), `version` (string, semver-ish), and
`description` (string, freeform). Anything else is a section, processed
by its registered handler.

All `path` fields inside sections are resolved relative to the plugin's
directory.

### Built-in sections (covered by this spec)

```toml
[samples]
roots = ["./samples", "./other/folder"]

[synthdefs]
files = ["./synths/foo.scd", "./synths/bar.scd"]

[julia]
files = ["./hooks.jl"]    # included in `Main` at load time, BEFORE
                          # other sections run, so the included Julia
                          # can register new section handlers.

depends_on = ["other-plugin"]   # optional load-order hint at top level.
```

### Future sections (other sub-projects)

`[instruments]`, `[recordings]`, `[midi-bindings]`, ... will be added by
their respective sub-projects. The loader is forward-compatible with any
section name; unknown sections log a `[WARN] no handler for 'X' in
'<plugin>'` and processing continues.

## 5. Section handler registry

The public extension API:

```julia
# in src/plugins.jl
const _SECTION_HANDLERS = Dict{Symbol, Function}()

"""
    register_section_handler!(section::Symbol, handler::Function)

Register `handler` to process manifests' `[<section>]` blocks. `handler`
is called with three arguments:

  handler(plugin_dir::String, section_data, plugin_name::String) -> Nothing

`section_data` is whatever TOML.parsefile returned for that key — usually
a Dict, sometimes a Vector. The handler is expected to do whatever side
effect makes the section "loaded" (push samples to SuperDirt, eval
SynthDefs, etc.) and may throw — exceptions are caught by the loader and
logged as `[ERROR] plugin '<name>' section '<X>': …`, then processing
continues with the next section.

Overwriting an existing handler is allowed and logs a `[WARN]`.
"""
function register_section_handler!(section::Symbol, handler::Function) ... end
```

Ressac core calls `register_section_handler!` for `:samples`,
`:synthdefs`, `:julia` at module load time. Third-party Julia in a
`[julia]` block can call it too — that's how new section types appear.

## 6. Load flow

`start_live!()` (and `live()` indirectly) gains a new step at the very
end, after the scheduler thread is started:

```julia
function start_live!(; ..., plugins::Bool = true)
    ...
    start!(sched)
    plugins && _load_plugins()
    return sched
end
```

`_load_plugins()`:

1. Walk the search path. Collect plugin directories that have a
   `plugin.toml`. First hit per name wins.
2. Topological-sort by `depends_on`. Plugins with no deps go first; cycle
   errors abort that plugin's load with a logged error.
3. For each plugin, in topo order:
   a. Parse `plugin.toml`. Validate `name` matches the dir name.
   b. If `[julia]` section: include its files into `Main` synchronously.
      This is the only section that runs out-of-registry order — it
      always runs first because it can mutate the registry.
   c. For each remaining section: look up the handler; call it under
      try/catch; log on error or missing handler.
   d. Log `[INFO] loaded plugin: <name> <version>  (<short summary>)`.

There is no hot-reload in this sub-project. Users restart Ressac to
pick up plugin changes. We add hot-reload later if it becomes painful.

## 7. Built-in handler: `[samples]`

Input: `{ "roots" = ["./samples", ...] }`.

Behaviour: for each root, ensure the path exists, then send a SuperDirt
OSC message that asks scsynth to scan the folder and add it to the
sample library. SuperDirt has an OSC interface for this: `~dirt.loadSoundFiles("<path>/*")`.

We send a custom OSC message `/dirt/loadSampleFolder` with the absolute
path as a `String` argument. SuperDirt-side, we add a small `OSCdef` in
our `scripts/superdirt-startup.scd` that listens for this and calls
`~dirt.loadSoundFiles("<path>/*")`.

Side effect: SuperDirt indexes the new samples. The sample base name
(filename without extension) becomes the `s` value usable in patterns.
If two folders contain `kick.wav`, SuperDirt's own ordering wins —
documented as a known limitation; future sub-project 4 (instruments)
gives a deterministic naming via aliases.

Errors:
- Root path doesn't exist → `[ERROR] plugin '<n>' samples: path '<x>' not found`
- No active scheduler (no OSC client to send through) → `[ERROR] cannot
  load samples: no active session`

## 8. Built-in handler: `[synthdefs]`

Input: `{ "files" = ["./synths/foo.scd", ...] }`.

Behaviour: for each file, read its content, send to SuperDirt via a
custom OSC message `/dirt/evalSC` with the SCD source as a String. The
companion OSCdef in `superdirt-startup.scd` interprets the string as
SC code via `interpret(source)`.

This is intentionally trusting: users are running their own SC code in
their own SuperDirt process. The plugin author owns the SCD code; the
user reads it before installing the plugin. Same trust model as any
package manager.

Errors: file missing, OSC send failure → logged per the standard handler
pattern.

## 9. Built-in handler: `[julia]`

Input: `{ "files" = ["./hooks.jl", ...] }`.

Behaviour: for each file, `Base.include(Main, file)`. This runs the
Julia code in `Main`'s scope; it can call
`Ressac.register_section_handler!`, define helpers, install new
combinators, etc.

This handler runs FIRST inside each plugin's section loop, before the
other sections of the same plugin, so that custom section handlers it
defines are visible to subsequent sections in the same plugin (rare but
useful).

Errors: include errors are caught and logged. The rest of the plugin's
sections still attempt to load — the user may want a partial load
rather than an all-or-nothing failure.

## 10. File layout

| File | Status | Purpose |
|---|---|---|
| `src/plugins.jl` | **new** | Registry, loader, search-path walk, topo sort. |
| `src/plugin_handlers.jl` | **new** | Built-in handlers for samples / synthdefs / julia. |
| `src/Ressac.jl` | extend | Include both new files, export `register_section_handler!` and `load_plugin`. Wire `_load_plugins()` into `start_live!`. |
| `scripts/superdirt-startup.scd` | extend | Add OSCdefs for `/dirt/loadSampleFolder` and `/dirt/evalSC`. |
| `test/test_plugins.jl` | **new** | Loader tests with a fixture plugin tree, handler-registry tests, error-path tests. |
| `test/fixtures/plugins/foo/plugin.toml` | **new** | Hand-rolled fixture plugin tree (samples + synthdefs + julia + bad cases). |
| `test/runtests.jl` | extend | Include `test_plugins.jl`. |
| `docs/cheatsheet.md` | extend | Add "Plugins" section explaining the search path and minimal manifest. |

## 11. Test strategy

Hard problems: `[samples]` and `[synthdefs]` send real OSC. To unit-test
without SuperDirt running, we'll have a tiny test seam in the handlers:
they call a `_send_to_dirt(client, address, args)` helper. Tests inject
a `MockOSCClient`-style sink (already in `test_scheduler.jl`) via the
active scheduler, and assert on the bytes shipped.

Concrete tests:
- Registry: `register_section_handler!`, overwrite warns, get/has.
- Search-path resolution: priority order, first-hit-wins, conflict
  warning, dirs without `plugin.toml` ignored.
- Topological sort: simple deps, missing dep errors gracefully, cycle
  detection.
- Loader end-to-end: fixture plugin with all four built-in sections;
  verify mock OSC client got the expected packets and Julia file was
  included.
- Error paths: malformed TOML, missing required key, handler throws —
  loader continues with the next plugin.
- Forward compat: manifest with an unknown section logs warning, doesn't
  crash, other sections still load.

## 12. Out of scope (deferred to later sub-projects)

- **Instruments** (sub-project 4): the `[instruments]` section, the
  event-to-OSC extension to carry multiple parameters.
- **Live recording** (sub-project 5): audio capture and sample-bank
  injection.
- **In-app sound design** (sub-project 6).
- **Hot-reload** of plugins without restarting Ressac.
- **Plugin uninstall / unregister** flow.
- **Plugin metadata browser** in the TUI (would belong with sub-project
  4 once instruments make plugin contents discoverable in patterns).
- **Versioning / dependency resolution** beyond the simple `depends_on`
  ordering hint. No semver constraints, no upgrade path.
- **Sandboxing** of plugin Julia / SC code. Plugins run with full
  access; the trust model is "you cloned it, you read it".

## 13. Why this is "organic"

The deliberate non-features:
- The core knows nothing about audio. Adding MIDI, OSC routing, lighting
  control, or anything else is a third-party plugin away.
- The registry uses the SAME API for built-in and external handlers. No
  privileged path.
- Manifests are plain TOML; anyone with a text editor can write one.
- A plugin is a directory; share it via git, tarball, USB stick.
- Forward-compat by default: unknown sections warn, don't crash.
- One required file (`plugin.toml`), three required keys. Everything
  else is optional.
