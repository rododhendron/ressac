# Instrument presets + synth listing + `:guide` — Design

> Sub-project 4. Adds the **instrument preset** abstraction (a named bundle
> of sample/synth + canned OSC params, expanded at fire-time via the same
> dispatch path as plain samples), folds in **synth listing/metadata** from
> the deferred sub-project 3, and ships a `:guide` ex-command for in-TUI
> command discovery. Multi-param events are still per-name (no per-event
> override) — that lives in sub-project 5 with the effect combinators and
> the mini-notation `#` operator.

## 1. Goal

After this sub-project, a plugin author can write:

```toml
[instruments.kicklourd]
s    = "bd"
n    = 3
gain = 1.2
lpf  = 200
tags = ["heavy", "subby"]
description = "the kick that hurts"

[synths.bassline]
tags = ["bass", "low"]
description = "warm sub bass"
```

And the user can:

```
@d1 p"kicklourd hh sn kicklourd"   # plays bd:3 with gain 1.2 lpf 200, not raw bd
K on `kicklourd`                    # previews with full params
:instruments                        # lists all presets
:synths                             # lists synths exposed by plugins
:guide                              # dumps every binding + syntax to logs
```

Plus the existing `bd`, `hh`, `sn` keep working — the dispatch falls back
to a plain `s "<name>"` when the symbol isn't a known instrument.

## 2. UX walkthrough

### Plugin author

```
plugins/funkit/
├── plugin.toml
├── samples/        # sub-project 1 style
├── curated/        # sub-project 2 [samples.bank] entries
└── synths/
    └── bassline.scd
```

```toml
name        = "funkit"
version     = "0.2.0"
description = "kit + synth + curated presets"

[samples]
roots = ["./samples"]

[samples.bank]
snares = "./curated/snares"

[synthdefs]
files = ["./synths/bassline.scd"]

[synths.bassline]
tags = ["bass", "low"]
description = "warm sub bass"

[instruments.kicklourd]
s    = "bd"
n    = 3
gain = 1.2
lpf  = 200
tags = ["heavy"]
description = "the kick that hurts"

[instruments.bassy]
s     = "bassline"
freq  = 110
amp   = 0.6
attack = 0.01
tags = ["bass", "deep"]
```

### Performer

```
> @d1 p"kicklourd hh sn kicklourd" |> fast(2)
[INFO] eval d1 ⇒ nothing

:instruments<Enter>
── funkit ──
  bassy       s=bassline freq=110 amp=0.6   [bass, deep]
  kicklourd   s=bd n=3 gain=1.2 lpf=200      [heavy] — "the kick that hurts"

:synths<Enter>
── funkit ──
  bassline    [bass, low] — "warm sub bass"

:guide<Enter>
[INFO] Ressac quick reference:
[INFO]   modes:  i/a/o/O insert  Esc normal  V visual  : command
[INFO]   nav:    h j k l   0 $   gg G
[INFO]   edit:   x  dd  yy  [N]yy  p P
…
```

Cursor on `kicklourd`, press `K`: plays `/dirt/play s "bd" n 3 gain 1.2 lpf 200` immediately.

## 3. Architecture

The whole sub-project is a **non-breaking extension**. Pattern and Event
types are unchanged. The dispatch path in `event_to_osc` grows a registry
lookup that returns multi-arg OSC for known instruments, and otherwise
falls back to today's single-arg form.

### Registries

In `src/plugins.jl`, two new module-level Dicts:

```julia
struct InstrumentEntry
    name::Symbol
    plugin::String
    # `Vector{Pair{String,Any}}` (not OrderedDict) keeps a zero-dep
    # ordering guarantee — the param order matches the TOML manifest
    # which is the author's intent.
    params::Vector{Pair{String,Any}}
    metadata::Dict{String,Any}    # tags, description, …
end

const _INSTRUMENT_REGISTRY = Dict{Symbol,InstrumentEntry}()

struct SynthEntry
    name::Symbol
    plugin::String
    metadata::Dict{String,Any}
end

const _SYNTH_REGISTRY = Dict{Symbol,SynthEntry}()

# Public helpers (same shape as sample_info / list_samples)
instrument_info(name::Symbol) :: Union{InstrumentEntry,Nothing}
synth_info(name::Symbol)      :: Union{SynthEntry,Nothing}
list_instruments(pattern::Regex = r"") :: Vector{InstrumentEntry}
list_synths(pattern::Regex = r"")      :: Vector{SynthEntry}
register_instrument!(entry::InstrumentEntry)
register_synth!(entry::SynthEntry)
```

Shadow semantics match sample registry: first-wins + `@warn`.

### Manifest format

#### `[instruments.<name>]`

Flat table. Required key: `s` (string — the sample or synth to dispatch
to). Reserved metadata keys: `tags`, `description`, `comment`. Everything
else passes through to `/dirt/play` in declared order.

```toml
[instruments.kicklourd]
s     = "bd"
n     = 3
gain  = 1.2
lpf   = 200
tags  = ["heavy"]
description = "the kick that hurts"
```

The handler validates `s` is present + a string. Reserved keys are pulled
into `metadata`; everything else is appended to `params` as
`Pair{String,Any}`s in TOML declaration order.

#### `[synths.<name>]`

Metadata-only table. The actual synth loading happens via
`[synthdefs] files = [...]` (sub-project 1). This section just exposes
the synth name + metadata to introspection and preview.

```toml
[synths.bassline]
tags = ["bass", "low"]
description = "warm sub bass"
```

No required keys. Anything declared is stored as metadata.

### Dispatch — extending `event_to_osc`

Today (in `src/scheduler.jl`):

```julia
event_to_osc(ev::Event{Symbol}) =
    OSCMessage("/dirt/play", Any["s", String(ev.value)])
```

New body:

```julia
function event_to_osc(ev::Event{Symbol})
    inst = instrument_info(ev.value)
    if inst === nothing
        return OSCMessage("/dirt/play", Any["s", String(ev.value)])
    end
    args = Any[]
    for (k, v) in inst.params
        push!(args, String(k))
        push!(args, _osc_value(v))
    end
    return OSCMessage("/dirt/play", args)
end
```

`_osc_value` converts TOML types to OSC-compatible:

| TOML  | OSC tag | Note |
|---|---|---|
| `Int` (any width) | `i` (Int32) | clamped to `Int32`; warn on overflow |
| `Float64`         | `f` (Float32) | precision narrowed |
| `String`          | `s` | passes through |
| `Bool`            | `i` (1 or 0) | SuperDirt convention |
| anything else     | dropped + `@warn` |

This conversion lives in `src/plugin_handlers.jl` next to the
`_handle_instruments` handler because that's where it's authored.

The fallback (`inst === nothing`) ALSO preserves the case where the
symbol is a synth name (`:bassline`): SuperDirt distinguishes
sample-name vs synth-name internally via `~dirt.soundLibrary` lookup,
so a plain `s "bassline"` works as long as the SynthDef has been
loaded by `[synthdefs]`.

### Handlers

Two new section handlers, registered at module load:

```julia
register_section_handler!(:instruments, _handle_instruments)
register_section_handler!(:synths, _handle_synths)
```

Both follow the same pattern as `_handle_samples`: walk the manifest
sub-tables, build the entries, call the registry's `register_*!`.
Neither needs OSC — instruments are dispatched purely Julia-side via
`event_to_osc`, and synth metadata never touches SuperDirt.

### TUI bindings

#### `:instruments` ex-command

`:instruments` (no arg) — list all, grouped by plugin, one line per
preset showing `s=…` summary + tags + first line of description.

`:instruments <glob>` — filter by glob.

`:instruments <name>` — full detail (all params + metadata) into logs.

Pattern matches the existing `_execute_samples_command!`.

#### `:synths` ex-command

`:synths` / `:synths <glob>` / `:synths <name>` — same shape as
`:instruments`, against `_SYNTH_REGISTRY`.

#### `:guide` ex-command

Dumps a hard-coded reference to `m.logs`. Sections:
- Mode keys
- Navigation
- Editing
- Eval (immediate vs +N)
- Goto / search
- Live API (`@d1`, etc.)
- Sound discovery (`K`, `:samples`, `:synths`, `:instruments`)
- Mini-notation syntax
- Command list (`:q`, `:cps`, `:goto`, `:samples`, `:synths`,
  `:instruments`, `:guide`)

Implementation: a `const _GUIDE_LINES::Vector{String}` in
`src/tui_bindings.jl`, looped through `_push_log!`. Long enough that
it pushes other logs out of the 8-line view, but the user can scroll
the logs panel up if/when scrolling exists (sub-project 6 territory).

For v1, `_GUIDE_LINES` is the literal cheatsheet text trimmed to fit
~30 lines.

#### `K` extension

The preview helper from sub-project 2 currently checks only
`_SAMPLE_REGISTRY`. Extend the resolution order (per user's vote):

1. `_INSTRUMENT_REGISTRY` (most specific — user-defined preset wins)
2. `_SAMPLE_REGISTRY`
3. `_SYNTH_REGISTRY`

If found as an instrument: send the full multi-arg `/dirt/play`. If
sample/synth: single-arg `s "<name>"` (with optional `n` if the cursor
word has `:N`). If nothing matches: log `[WARN] no sample/instrument/
synth '<word>' loaded`.

## 4. File layout

| File | Status | Responsibility |
|---|---|---|
| `src/plugins.jl` | extend | Add `InstrumentEntry`, `SynthEntry`, two registries, four `*_info` / `list_*` / `register_*!` helpers. |
| `src/plugin_handlers.jl` | extend | `_handle_instruments`, `_handle_synths`, `_osc_value` converter. Register both handlers. |
| `src/scheduler.jl` | extend | Rewrite `event_to_osc(::Event{Symbol})` to consult `_INSTRUMENT_REGISTRY`. |
| `src/tui_bindings.jl` | extend | `:instruments`/`:synths`/`:guide` in `_execute_ex_command!`; extend `_preview_under_cursor!` to walk 3 registries. Add `_GUIDE_LINES`. |
| `src/Ressac.jl` | extend | Export `InstrumentEntry`, `instrument_info`, `list_instruments`, `SynthEntry`, `synth_info`, `list_synths`, `register_instrument!`, `register_synth!`. Extend precompile workload. |
| `test/test_plugins.jl` | extend | Registry round-trip tests for both new registries. |
| `test/test_plugin_handlers.jl` | extend | `[instruments]` and `[synths]` loading; `_osc_value` conversions. |
| `test/test_scheduler.jl` | extend | `event_to_osc` extension: known instrument → multi-arg, unknown → single-arg. |
| `test/test_tui_bindings.jl` | extend | `:instruments`/`:synths`/`:guide` ex-commands; K resolves instrument over sample. |
| `test/fixtures/plugins/withinst/` | **new** | Fixture: `[instruments.kicklourd]` + `[synths.bassline]` + metadata. |
| `docs/cheatsheet.md` | extend | New section: "Instruments & synths" with the workflow + `:guide` mention. |

## 5. Test strategy

End-to-end coverage via `MockOSCClient` for OSC paths, no SuperDirt
needed:

- Manifest with `[instruments.kicklourd]` populates
  `_INSTRUMENT_REGISTRY` with the right entry; params order matches
  the TOML; reserved keys → metadata, others → params.
- `[synths.bassline]` populates `_SYNTH_REGISTRY` with metadata only.
- `event_to_osc(Event(0//1, 1//4, :kicklourd))` builds
  `OSCMessage("/dirt/play", Any["s", "bd", "n", Int32(3), "gain", Float32(1.2), "lpf", Int32(200)])`.
- Plain `Event(0//1, 1//4, :bd)` (no instrument by that name) still
  builds the single-arg form.
- `_osc_value`: Int → Int32, Float64 → Float32, String pass-through,
  Bool → 1/0, unknown type → warn + skip.
- `K` preview on word "kicklourd": looks up instrument, multi-arg OSC
  shipped.
- `K` on "bd" when both sample and instrument exist for `bd`: instrument
  wins.
- `:instruments`, `:synths` ex-commands list, filter by glob, and show
  detail.
- `:guide` writes the reference text to `m.logs`.

## 6. Out of scope (deferred)

- **Effect pipeline combinators** (`p |> reverb(0.5)`) — sub-project 5.
  Requires the multi-param event refactor.
- **Pattern-level overrides** (`p"bd # gain 0.8"`) — sub-project 5.
  Mini-notation extension.
- **Modulation patterns** — params that are themselves Patterns rather
  than constants (Tidal's `gain "0.8 1.0 0.5"`). Future.
- **Instrument inheritance / `extends`** — over-engineering for v1.
- **Live editing of instruments from the TUI** — sub-project 6.
- **`:guide` interactive mode** with sections / search — sub-project 6
  (visual UX deep dive).
- **Per-mode keybinding hint widget** in the TUI — sub-project 6.
- **Auto-complete on sample/synth/instrument names** while typing —
  sub-project 6.

## 7. Compatibility

- All sub-project 1+2 plugins continue to work. Plugins that don't
  declare `[instruments]` or `[synths]` see no change in behaviour;
  the dispatch falls through to the existing sample/synth path.
- `event_to_osc(Event{Symbol})` keeps its current behaviour for any
  Symbol that isn't in `_INSTRUMENT_REGISTRY`. The 367 existing tests
  must stay green after this change.
- The existing `[synthdefs]` handler is untouched. `[synths.<name>]`
  is purely additive — only adds discoverability and metadata; doesn't
  load anything.

## 8. Why this scope is right

- All four features (instruments, synth listing, `K` extension,
  `:guide`) share the registry pattern of sub-project 2. The
  implementation is mostly mechanical extension, not new architecture.
- The big architectural refactor (multi-param events) is **explicitly
  deferred to sub-project 5** because it's only required by effect
  pipelines and pattern-level overrides. Doing it here would mix two
  unrelated changes in one sub-project.
- `:guide` is the cheapest possible discoverability win — a const
  vector of strings dumped to logs. The richer UX (interactive guide,
  permanent hint widget, autocomplete) is sub-project 6.
