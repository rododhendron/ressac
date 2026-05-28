# Sub-project 8 — SC UGen doc autodiscover (Stage A)

Status: approved 2026-05-29.

## Goal

Auto-populate the `_DOCS` registry with one entry per SuperCollider
UGen (~500-600 entries) so the live doc tooltip + `:doc <UGenName>`
works for every UGen out of the box, not just the ~50 hand-written
entries currently in `_SC_UGEN_DOCS`. Each entry includes:

- A short tooltip description parsed from the UGen's SCDoc HelpFile.
- The full signature for each rate (`.ar`, `.kr`, `.ir`) with arg
  names and default values.
- A complete Markdown body reformatted from SCDoc, ready for the
  future doc-pane to render directly.

The infrastructure for storage, lookup, and aliasing already exists
from sub-project 7. This sub-project only adds the SC-side discovery
flow + a cache invalidation mechanism + a loader path extension.

## Non-goals

- No code generation. Auto-generating Julia wrappers (`SinOsc.ar` →
  `SynthDSL.sinosc(...)`) is a separate, much riskier project — that's
  sub-project 11 (Stage B), deferred until we see how Stage A lands.
- No HTML rendering of the SCDoc body. The MD body is stored verbatim
  for the future doc-pane to consume; tooltip uses the parsed `short`
  field only.
- No replacement of the existing `_SC_UGEN_DOCS` Dict in
  `tui_livedoc.jl`. That fallback stays for now — it covers the same
  ground for the 50 most common UGens and acts as a safety net when
  the cache is missing or corrupted.
- No SC headless integration in CI. UGen tests are manual smoke
  tests, not automated against a running SC.

## Architecture

Three abstractions:

- **`plugins/sc-discoverer/`** — a tiny plugin (~50 lines of Julia +
  a single `.scd`) that owns the discovery logic. Coherent with the
  sub-project 7 "everything is a plugin" philosophy. Named
  `sc-discoverer` rather than `sc-autodiscover` so it doesn't
  collide with the generated content plugin in the cache (see
  "Boot lifecycle" below for the rationale).
- **`~/.cache/ressac/plugins/sc-autodiscover/`** — the generated
  output: a plugin manifest + one MD file per UGen + a
  `cache_meta.json` invalidation signature. Treated as a regular
  plugin by the loader.
- **Plugin loader extension** — `default_plugin_path()` adds the
  user cache directory to its scan list, after the project tree and
  config user. Last-wins on conflicts means user overrides win.

The discovery script runs **only when the cache is invalid**. On a
warm boot (cache fresh), the loader just reads the generated MD
files at normal plugin-load speed.

## File layout

```
plugins/sc-discoverer/              # runner plugin (in project repo)
├── plugin.toml                     # [julia] + [sc_discover] sections
├── bootstrap.jl                    # _handle_sc_discover, ack listener
└── discover.scd                    # SC script (~250 lines)

~/.cache/ressac/plugins/sc-autodiscover/   # generated content plugin
├── plugin.toml                     # auto-generated, declares [docs]
├── cache_meta.json                 # invalidation signature
└── docs/
    ├── SinOsc.md
    ├── EnvGen.md
    ├── LFNoise0.md
    └── … (~500-600 files)
```

## Boot lifecycle

Today (post sub-project 7):

```
start_live!
  → discover_plugins([plugins/, ~/.config/ressac/plugins])
  → topo_sort
  → load_plugin foreach (core first)
  → _resolve_snippet_includes!
```

After this sub-project:

```
start_live!
  → SC connection established
  → discover_plugins([plugins/, ~/.config/ressac/plugins,
                      ~/.cache/ressac/plugins])   # NEW path
  → topo_sort
  → load_plugin foreach:
      - core
      - sc-discoverer (runner — in project)
          → [julia] bootstrap.jl runs (registers handler)
          → [sc_discover] section invoked:
              * roundtrip /ressac/sc-meta → sc_version + ugen_count
              * compare against cache_meta.json
              * cache valid → return (skip discovery)
              * cache invalid → send /dirt/evalSC <discover.scd>
                                → wait for /ressac/sc-discovery-done (30s timeout)
                                → cache now populated
      - … other plugins …
      - sc-autodiscover (content — from ~/.cache/ressac/plugins)
          → [docs] handler scans docs/*.md → register_doc! × ~600
  → _resolve_snippet_includes!
  → TUI starts; _DOCS has +~600 SC UGen entries
```

### Why two plugin names

The discovery flow needs two distinct plugins because the plugin
loader's `discover_plugins` uses "first-wins-by-name" — registering
the same plugin name from two different paths logs a shadow warning
and skips the second.

- `plugins/sc-discoverer/` (in the project tree) ships the runner:
  `[julia] bootstrap.jl` + a custom `[sc_discover]` section whose
  handler triggers the SC script. No `[docs]`. No content of its
  own.
- `~/.cache/ressac/plugins/sc-autodiscover/` (in the user cache)
  holds the generated content: `[docs] dir = "docs"` only. No
  `[julia]`, no `[sc_discover]`.

The runner triggers discovery (which generates the content). The
content plugin is loaded later in the same `_load_plugins` pass
because we scan paths sequentially and the cache path comes after
the project path.

## Discovery transport

A. **Trigger** — Ressac ships the SC script via the existing
   `/dirt/evalSC` OSC handler (already in
   `scripts/superdirt-startup.scd`). No new SC-side wire-up needed
   for the trigger itself.
B. **SC executes** — `discover.scd` iterates `UGen.allSubclasses`,
   builds the MD files in memory, writes them to disk one by one.
C. **Ack** — when finished, SC sends
   `/ressac/sc-discovery-done <ugen_count>` over OSC. Ressac listens
   via a temporary OSC handler installed at the start of the handler
   call.

## File formats

### `cache_meta.json`

```json
{
  "sc_version": "3.13.0",
  "ugen_count": 587,
  "generated_at": "2026-05-29T14:23:11Z",
  "discover_script_sha256": "a3f1b4…"
}
```

- `sc_version` — `Main.version` from SC.
- `ugen_count` — `UGen.allSubclasses.size`.
- `generated_at` — ISO 8601 timestamp, debug-only.
- `discover_script_sha256` — SHA-256 of `plugins/sc-discoverer/discover.scd`
  as it exists on disk at the moment of cache write. Lets us
  auto-invalidate the cache whenever the SC script changes (so the
  user never has to remember to bump a version constant by hand).
  Computed via the Julia `SHA` stdlib. Cosmetic-only edits (whitespace,
  comments) do trigger re-discovery — that's acceptable since
  re-discovery is rare (only at `start_live!`) and takes ~10s.

### MD file (example `SinOsc.md`)

````markdown
+++
aliases = []
examples = []
kwargs = ["freq", "phase", "mul", "add"]
name = "SinOsc"
short = "Interpolating sine wavetable oscillator."
tags = ["sc-ugen", "generator"]
+++

# SinOsc

## Signatures

- `SinOsc.ar(freq=440, phase=0, mul=1, add=0)`
- `SinOsc.kr(freq=440, phase=0, mul=1, add=0)`

## Description

A sine wave oscillator using wavetable interpolation. The output is
a sinusoidal waveform of the specified frequency.

## Arguments

- **freq** — Frequency in Hz.
- **phase** — Phase offset in radians.
- **mul** — Output multiplier (gain).
- **add** — Output DC offset.

## Examples

​```sclang
{ SinOsc.ar(440, 0, 0.2) }.play;
​```
````

Frontmatter rules:
- `name` — the UGen class name verbatim (e.g. `"SinOsc"`).
- `short` — the first paragraph of the SCDoc `description::` block,
  stripped of formatting markers, truncated to 200 chars max.
- `tags` — `["sc-ugen", <SCDoc category>]` (e.g. `"generator"`,
  `"filter"`, `"trigger"`). The category comes from the SCDoc
  `categories::` field, first segment after `UGens>` (e.g.
  `UGens>Generators>Deterministic` → `"generator"`).
- `kwargs` — flat list of all distinct arg names across all rates.
- `aliases` — empty by default (SC UGen names are already
  unqualified, so the sub-project 7 auto-basename alias doesn't
  apply).
- `examples` — left empty. SCDoc `examples::` blocks are embedded in
  the body's `## Examples` section; surfacing them as separate
  `examples = […]` entries in `:doc` is redundant.

## The SC discovery script

`discover.scd` is ~250 lines structured in five functions:

1. **`~ressacFindUgens`** — returns the filtered list of UGen
   subclasses (excludes pure abstractions that don't respond to
   `.ar`).

2. **`~ressacSignaturesFor { |class| … }`** — for a UGen class,
   returns a Dict keyed by rate (`'ar'`, `'kr'`, `'ir'`) whose
   values are `[(name, default), …]` sequences. Uses
   `class.class.findRespondingMethodFor(\rate)` then introspects
   the method's argNames + default values via SC's reflection.

3. **`~ressacScDocToMd { |helpPath| … }`** — opens the `.schelp`
   file, returns a tuple `(short, body, category)`. Implementation:
   - Read file as string.
   - Extract `categories::` line → first segment.
   - Find `description::` … `::` block, take first paragraph → `short`.
   - For each section (`description::`, `classmethods::`,
     `argument::*`, `examples::`), reformat to MD via string
     manipulation. ~80 lines of SC string code.

4. **`~ressacWriteUgenMd { |class, sigs, short, body, category| … }`**
   — composes the frontmatter dict, serializes via SC's JSON helper
   (`~ressacJsonEncode`), writes to
   `~/.cache/ressac/plugins/sc-autodiscover/docs/<ClassName>.md`.

5. **`~ressacMain { … }`** — orchestrator. Empties the cache dir,
   iterates UGens, calls the above for each, writes
   `cache_meta.json`, sends OSC ack.

The script also writes `plugin.toml` for the cached plugin (so the
generated tree is self-sufficient when scanned by the loader).

## The Julia handler

`plugins/sc-discoverer/bootstrap.jl`:

```julia
using SHA

# Override-able via env var RESSAC_CACHE_DIR (e.g. for read-only
# filesystem scenarios). Defaults to ~/.cache/ressac.
_sc_cache_dir() = joinpath(
    get(ENV, "RESSAC_CACHE_DIR", joinpath(homedir(), ".cache", "ressac")),
    "plugins", "sc-autodiscover",
)

_sc_script_sha256(scd_path) =
    bytes2hex(SHA.sha256(read(scd_path, String)))

function _sc_cache_valid(cache_dir, scd_path)
    meta_path = joinpath(cache_dir, "cache_meta.json")
    isfile(meta_path) || return false
    meta = try
        JSON.parse(read(meta_path, String))
    catch
        @warn "sc-autodiscover: cache_meta.json corrupted, will rediscover"
        return false
    end
    # Auto-invalidate when the SC script content changes — frees us
    # from maintaining a manual version constant. Cosmetic edits do
    # trigger re-discovery; acceptable since it's only at start_live!.
    current_sha = _sc_script_sha256(scd_path)
    get(meta, "discover_script_sha256", "") == current_sha || return false
    # Roundtrip /ressac/sc-meta to compare against live SC state.
    sc_version, sc_ugen_count = _sc_meta_roundtrip(; timeout = 3.0)
    sc_version === nothing && return false   # SC unreachable, assume invalid
    get(meta, "sc_version", "")  == sc_version  &&
    get(meta, "ugen_count", -1)  == sc_ugen_count
end

function _handle_sc_discover(plugin_dir, data, plugin_name)
    cache_dir = _sc_cache_dir()
    scd_path = joinpath(plugin_dir, "discover.scd")
    if _sc_cache_valid(cache_dir, scd_path)
        @info "sc-autodiscover: cache fresh, skipping discovery"
        return nothing
    end
    sched = _LIVE_SCHEDULER[]
    if sched === nothing
        @warn "sc-autodiscover: no live session, discovery deferred"
        return nothing
    end
    @info "sc-autodiscover: cache invalid, running discovery (may take ~10s)"
    mkpath(joinpath(cache_dir, "docs"))
    script = read(joinpath(plugin_dir, "discover.scd"), String)
    # Install ack listener BEFORE sending the eval, to avoid a race.
    ack_chan = Channel{Int}(1)
    _install_discovery_ack_listener(ack_chan)
    send_osc(sched.osc, encode(OSCMessage("/dirt/evalSC", Any[script])))
    try
        ugen_count = take_with_timeout(ack_chan, 30.0)
        @info "sc-autodiscover: discovered $ugen_count UGens"
    catch
        @error "sc-autodiscover: discovery timed out after 30s"
    finally
        _uninstall_discovery_ack_listener()
    end
end

register_section_handler!(:sc_discover, _handle_sc_discover)
```

The `_sc_meta_roundtrip` helper sends `/ressac/sc-meta` and waits
for `/ressac/sc-meta-reply <version> <count>` with a 3s timeout. The
matching SC-side handler is a 5-line OSCdef added to
`scripts/superdirt-startup.scd`:

```scd
OSCdef(\ressacScMeta, { |msg, time, addr|
    addr.sendMsg("/ressac/sc-meta-reply", Main.version, UGen.allSubclasses.size);
}, '/ressac/sc-meta');
```

`_install_discovery_ack_listener` reuses the existing OSC dispatch
infrastructure in `src/tui_scope.jl` (which already handles
`/ressac/*` packets in a callback). The temporary handler routes
the `<ugen_count>` arg into the channel and uninstalls on receipt.

## Loader path extension

Single edit in `src/plugin_registry.jl`:

```julia
function default_plugin_path()
    path = String[joinpath(pwd(), "plugins")]
    push!(path, joinpath(homedir(), ".config", "ressac", "plugins"))
    push!(path, joinpath(homedir(), ".cache",  "ressac", "plugins"))  # NEW
    extra = get(ENV, "RESSAC_PLUGIN_PATH", "")
    if !isempty(extra)
        for entry in split(extra, ':')
            isempty(entry) || push!(path, String(entry))
        end
    end
    return path
end
```

Order is intentional: project > config > cache. A user plugin in
`~/.config/ressac/plugins/my-overrides/docs/SinOsc.md` is loaded
before the generated cache one; last-wins on conflict means the
override is what `lookup_doc("SinOsc")` returns.

## User-facing commands

- `:sc-rediscover` — force re-discovery. Deletes
  `cache_meta.json` (not the docs, in case discovery fails halfway,
  the old MD files stay readable) then calls
  `_handle_sc_discover(...)` synchronously.
- `:sc-cache-info` — log the contents of `cache_meta.json` + the
  cache directory path.

Both are registered in `tui_app.jl` as `_register_literal!` actions.
They require an active live session; on no-session, log an error.

## Error handling

| Scenario | Policy |
|---|---|
| SC not started at handler invocation | `[WARN] sc-autodiscover: no live session, discovery deferred`; skip. Discovery retried at next `start_live!`. |
| `/ressac/sc-meta` roundtrip timeout (3s) | Assume cache invalid → trigger full discovery as fallback. |
| Full discovery timeout (30s) | `[ERROR] sc-autodiscover: discovery timed out`. `cache_meta.json` not written, so next boot retries. Existing MD files (if any) are still loaded. |
| Cache dir not writable | `[ERROR] sc-autodiscover: cache write failed: <reason>`. Boot continues without SC UGen docs. |
| Single MD file fails to parse | Per-file warning, skip that entry. Other files load normally (already handled by `_handle_docs` from sub-project 7). |
| Corrupted `cache_meta.json` | `[WARN] sc-autodiscover: cache_meta.json corrupted, will rediscover`; treat as invalid. |
| User has no SC and triggers `:sc-rediscover` | `[ERROR] :sc-rediscover requires an active SC session — start the live first`. |

## Testing

**Unit tests (`test/test_sc_autodiscover.jl`)**, no SC required:

- `_sc_cache_valid`:
  - Mock `cache_meta.json` with matching SC version + UGen count +
    script SHA → true.
  - SC version mismatch → false.
  - UGen count mismatch → false.
  - Missing file → false.
  - Corrupted JSON → false + warning.
  - SC script SHA mismatch (simulate by writing a modified
    `discover.scd` to a tmp path) → false.

- `_sc_script_sha256`:
  - Identical content → identical hash.
  - One-byte edit → different hash.

- Loader integration with a synthetic cache:
  - Fixture cache dir with 3 pre-written MD files (no SC involved).
  - Run `_load_plugins` with the cache dir included in the path.
  - `lookup_doc("MockUGen1")` returns an entry with `body != ""`.
  - `lookup_doc` resolves the alias (basename) — same as sub-project 7 behavior.

- `_handle_sc_discover` short-circuit when cache valid:
  - Set up a fresh cache + meta matching expected version.
  - Mock `_sc_meta_roundtrip` to return matching values.
  - Call the handler; verify no OSC is sent.

- Path extension:
  - `default_plugin_path()` returns the cache dir as the third entry.

**Integration tests** (manual, documented in design):

1. **Cold-cache discovery**: `rm -rf ~/.cache/ressac/plugins/sc-autodiscover/`,
   start live, verify ~300+ MD files appear under
   `~/.cache/ressac/plugins/sc-autodiscover/docs/` within 30s.
2. **Live doc**: `:doc SinOsc` returns a non-empty tooltip and
   examples; hover over `EnvGen` in the synth editor shows a tooltip.
3. **Warm-cache boot**: restart live, verify no discovery is
   triggered (no `[INFO] sc-autodiscover: cache invalid` log) and
   `lookup_doc("SinOsc")` still works.
4. **Forced re-discovery**: `:sc-rediscover` re-runs discovery
   without manual cache cleanup.
5. **Invalidation**: manually edit `sc_version` in
   `cache_meta.json`, restart, verify re-discovery triggers.

**SC script syntax check**:
- `sclang -h discover.scd` in CI lints the SC script (parse only,
  no execution) so we catch typos without running a server.

## Acceptance criteria

Sub-project 8 is done when:

1. `plugins/sc-discoverer/` exists with `plugin.toml` (declaring a
   `[sc_discover]` section + `[julia] files = ["bootstrap.jl"]`),
   `bootstrap.jl`, `discover.scd`.
2. The plugin loader scans `~/.cache/ressac/plugins/` after the
   user config dir.
3. On a clean install (no cache), `start_live!` populates
   `~/.cache/ressac/plugins/sc-autodiscover/docs/*.md` with at
   least **300 UGens** (filter for non-abstract = ~80 % of ~600
   subclasses).
4. Each generated MD file has valid frontmatter (`name`, `short`
   non-empty when SCDoc exists, `tags` including `"sc-ugen"`,
   `kwargs`).
5. `lookup_doc("SinOsc")`, `lookup_doc("EnvGen")`,
   `lookup_doc("LFNoise0")` return entries with `body != ""`.
6. Warm-boot (cache valid) does not trigger discovery. Boot time
   ≤ 350 ms (vs ~200 ms baseline from sub-project 7).
7. `:sc-rediscover` re-triggers discovery without manual cache
   cleanup. `:sc-cache-info` logs the cache meta.
8. Test suite stays green (1509 existing + new SC autodiscover
   tests, all without requiring a live SC).
9. Manual integration test #1 (cold-cache discovery) completes in
   under 30s on a typical dev machine.

## Risks and mitigations

- **Risk**: `SCDoc.findHelpFile` lookup slow at 600 calls in
  sequence. **Mitigation**: First-boot only (cached afterwards).
  SCDoc internally caches lookups. If wall-clock > 30s, parallelize
  via `Routine.fork` for batches of 50 UGens.

- **Risk**: Third-party sc3-plugins ship UGens without proper
  `.schelp` files. **Mitigation**: `body = ""`, `short = ""`,
  `tags = ["sc-ugen"]` only. Signatures captured via introspection
  remain useful → tooltip shows args even without a description.

- **Risk**: Cache dir on read-only filesystem (Docker, Nix
  read-only stores). **Mitigation**: `RESSAC_CACHE_DIR` env var
  override documented in the design + docstring of `_sc_cache_dir`.

- **Risk**: Plugin name collision between the source (`sc-discoverer`)
  and the cached (`sc-autodiscover`) confuses users. **Mitigation**:
  Clear naming: "discoverer" = the runner that does the work,
  "autodiscover" = the auto-generated content. Documented in the
  bootstrap.jl docstring + design doc.

- **Risk**: SCDoc syntax variations across SC versions break the
  parser. **Mitigation**: Pin against SC 3.13+ behavior. `short`
  field gracefully degrades to `""` if extraction fails. Body just
  contains the partial reformat. We never crash the boot.

- **Risk**: A future sc3-plugin install (after first-boot) silently
  adds UGens that aren't in the cache. **Mitigation**: `ugen_count`
  in `cache_meta.json` catches this — next boot detects the
  mismatch and re-discovers automatically.

## Open questions deferred

- **Stage B (sub-project 11)**: codegen of Julia wrappers (`SinOsc.ar
  → SynthDSL.sinosc(...)`). Requires resolving CamelCase→snake_case,
  rate-method dispatch (`.ar` vs `.kr` vs `.ir`), and SC-specific
  argument quirks. Out of scope here.

- **Multi-version SC support**: if the user runs different SC
  versions for different projects, the cache currently isn't
  versioned by SC install path. Could add a hash of
  `Server.default.options.sclangPath` to the invalidation tuple.
  Not urgent — most users run one SC install.

- **Cache compression**: ~500 MD files = ~5 MB on disk total.
  Acceptable. If it becomes an issue, an option to gzip the body
  inside the JSON cache is straightforward.

- **Custom HelpFile authoring**: the user might want to customize
  the auto-generated SCDoc → MD conversion (e.g. add their own
  examples). Sub-project 7's last-wins on conflict means they can
  ship `~/.config/ressac/plugins/sc-overrides/docs/SinOsc.md` with
  their own content, which loads before the cache. No new mechanism
  needed.
