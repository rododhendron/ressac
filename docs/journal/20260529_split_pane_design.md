# Sub-project 9 — Split-pane UI (zellij-inspired workspaces + N-ary containers + tabs + floats)

Status: approved 2026-05-29.

## Goal

Replace Ressac's fixed-layout TUI (hardcoded `m.layout_patterns` /
`m.layout_synth` / `m.layout_log` / `m.layout_scope` rects computed
in `view()`) with a recursive split-pane system inspired by zellij
and vim. The user can split horizontally / vertically anywhere in
the tree, navigate between panes, dock / undock panes between tiled
and floating modes, and switch between named workspaces. Every UI
surface becomes a pane (the "everything is a pane" model from
sub-project 7's mental model). Pane kinds are plugin-extensible via
the same registry pattern as docs / snippets / SC autodiscover.

Concrete user-facing use cases unlocked:

- Hover an SC UGen in the editor → open its doc in a side pane
  without losing the code context (`:vsplit doc SinOsc` or auto-
  triggered by snippet `panes = [...]`).
- Code on the left, watch a scope (`:scope reservoir-graph`) on
  the right, all in the same workspace.
- Designing a complex synth → switch to a `synth-design` workspace
  with the synth editor + a preview scope pre-arranged; come back
  to `live` workspace with `Ctrl-1`.
- Apply `:starter reservoir-pop5` → entire workspace rebuilds with
  the snippet's declared `panes = [...]` layout (editor + scope +
  doc) instead of just dumping code into a single editor.

## Non-goals

- No migration of existing modal overlays in this sub-project.
  Mixer, browser, snippet picker, synth library, sccode, `:guide`
  stay as overlays exactly as today. Sub-project 10 will migrate
  them into the floating pane system.
- No new visualization kinds beyond what `:scope` already supports.
  Plugin-contributed kinds (reservoir-graph as its own kind, future
  spectrum analyzer, etc.) arrive in subsequent sub-projects.
- No mouse-driven splitting / resizing in this sub-project. Mouse
  support stays where it is today (click to focus). Mouse handlers
  on individual panes are in the `PaneImpl` contract but use the
  fallback no-op by default.
- No scroll mode (zellij's `Ctrl+S`). Julia's editor handles
  scrolling natively per-pane.
- No persistence of buffer content as part of the layout file —
  buffers are sidecar files. The layout file holds only
  structure + references.

## Architecture overview

Five abstractions form the system:

1. **`PaneImpl`** — abstract type. Each kind is a `struct <: PaneImpl`
   implementing 4 mandatory functions + optionally overriding 8
   defaulted ones. Single uniform interface; the layout manager only
   talks to `PaneImpl`.

2. **Registry** — `_PANE_KINDS::Dict{Symbol, Function}` where the
   value is a constructor `(args::Dict) -> PaneImpl`. Plugins
   register via `register_pane_kind!(:kind, MyImpl)`. Same pattern
   as sub-project 7's doc / snippet registry.

3. **Layout tree** — recursive `LayoutNode`:
   ```julia
   abstract type LayoutNode end
   mutable struct PaneLeaf <: LayoutNode
       id::Int
       tabs::Vector{PaneImpl}    # ≥ 1
       current_tab::Int
   end
   mutable struct Container <: LayoutNode
       direction::Symbol         # :h | :v
       children::Vector{LayoutNode}
       ratios::Vector{Float64}   # length = children, sum ≈ 1.0
   end
   ```
   N-ary containers (Section "Why N-ary internally") enable
   "3-column" layouts as a single node, with proportional resize
   across N children.

4. **Workspace** — top-level container:
   ```julia
   mutable struct Workspace
       id::Int
       name::String              # "" when untitled
       tree::LayoutNode          # the tiled tree
       floats::Vector{FloatingPane}
       focused_pane::Int         # PaneLeaf.id of the focused leaf
   end
   ```

5. **`WorkspaceManager`** — replaces `m.layout_*` on `RessacApp`:
   ```julia
   mutable struct WorkspaceManager
       workspaces::Vector{Workspace}
       current_idx::Int
       next_pane_id::Int
       next_workspace_id::Int
   end
   ```

### Why N-ary internally even though user model is binary

The user mental model from vim is "I split this pane horizontally /
vertically into two". That's a binary operation. But the resulting
tree, if naïvely stored, becomes lopsided after three or more
sibling panes (`VSplit(A, VSplit(B, VSplit(C, D)))`), making
resize semantics asymmetric (resizing A nudges the BCD container,
not A vs B).

The solution: store as N-ary, render as binary mental model. After
the user does C-w v three times, the tree is `Container(:h, [A, B,
C, D])` not the lopsided binary form. Resize hits whichever
direction the user indicates and adjusts the relevant pair of
ratios. The split operation itself is `split(leaf, :v)` →
"insert a new leaf as the next sibling of `leaf` in its parent
container; if the parent's direction doesn't match, wrap the leaf
in a new container of the requested direction".

Users perceive vim-like binary operations; the data structure
preserves the geometric symmetry.

## File layout

```
src/
├── pane_interface.jl          # abstract PaneImpl + 12-fn contract + defaults + registry
├── pane_editor.jl             # :editor kind (unifies patterns + synth editor)
├── pane_log.jl                # :log kind
├── pane_scope.jl              # :scope kind (subtypes: wave, spectrum, reservoir-graph, …)
├── pane_doc.jl                # :doc kind (reads DocEntry from sub-project 7 registry)
├── workspace_manager.jl       # LayoutNode, Container, PaneLeaf, FloatingPane, Workspace, WorkspaceManager
├── workspace_persistence.jl   # save/load TOML, last_layout.toml + ~/.config/ressac/layouts/
├── workspace_commands.jl      # ex commands (:split, :vsplit, :focus, :close, …)
├── workspace_keymap.jl        # C-w pane mode + resize mode + Ctrl-N globals
└── tui_app.jl                 # WorkspaceManager replaces m.layout_*; view() shrinks dramatically

plugins/sc-discoverer/         # unchanged from sub-project 8
plugins/sc-autodiscover/       # unchanged
…
test/
├── test_pane_interface.jl
├── test_workspace_manager.jl
├── test_workspace_persistence.jl
├── test_snippet_panes.jl      # extends sub-project 7 integration tests
└── test_workspace_commands.jl
```

`tui_app.jl` shrinks by ~300 lines (the fixed-rect calculation
disappears).

## `PaneImpl` contract — 4 mandatory + 8 defaulted

```julia
abstract type PaneImpl end

# Mandatory — every kind must implement these.
render!(p::PaneImpl, area::Rect, buf::Buffer)
handle_key!(p::PaneImpl, evt::KeyEvent)::Bool   # true = consumed
title(p::PaneImpl)::String
# new_pane(args::Dict) -> PaneImpl is the constructor, registered
# by name in _PANE_KINDS, not an instance method.

# Defaulted — override only when you need different behavior.
default_mode(::PaneImpl)::Symbol            = :tile
serialize(::PaneImpl)::Dict{String,Any}     = Dict()
on_focus!(::PaneImpl)                       = nothing
on_blur!(::PaneImpl)                        = nothing
on_close!(::PaneImpl)                       = nothing
handle_mouse!(::PaneImpl, ::MouseEvent)::Bool = false
preferred_size(::PaneImpl)::Union{Nothing,Tuple{Int,Int}} = nothing
can_split(::PaneImpl)::Bool                 = true
sidebar(::PaneImpl)::Vector{String}         = String[]
```

A minimal viable kind = 4 functions. A rich kind (e.g. `:scope`
that needs `on_close!` to unsubscribe from OSC + `serialize` for
the subtype + `default_mode = :tile`) overrides 3-5 of the
optionals.

`register_pane_kind!`:
```julia
function register_pane_kind!(name::Symbol, ctor::Function)
    haskey(_PANE_KINDS, name) &&
        @warn "pane kind '$name' is being shadowed"
    _PANE_KINDS[name] = ctor
end
```
Last-wins on conflict, with warning — same convention as docs /
snippets.

## Core kinds (registered by Ressac core at boot)

Dogfooding pattern: Ressac core registers its 4 kinds via the same
`register_pane_kind!` plugins would call. No special-casing.

### `:editor` — unified patterns + synth editor

Patterns editor and synth editor share ~90% of the code (text
buffer, modal vim, autocomplete, tabs). The 10% difference (eval
target, completion context, buffer semantics) is per-buffer state,
not per-kind.

```julia
struct EditorBuffer
    content::String
    cursor::CursorState
    role::Symbol               # :patterns | :synth
    name::String               # "main.jl" or "wob1" etc.
    eval_target::Symbol        # :slot | :sc_eval
    completion_ctx::Symbol     # :patterns_dsl | :synth_dsl | :sc_ugens
end

struct EditorPane <: PaneImpl
    tabs::Vector{EditorBuffer}
    current_tab::Int
end
```

A single `:editor` pane can mix patterns and synth tabs. `<C-w>t`
opens a new tab; tab role is determined by the args passed to
`new_pane` (or from the focused-buffer convention).

Eval routing (current `e` and `T` keys) dispatches on the focused
buffer's `eval_target`, not on the pane kind.

### `:log` — global log tail

Reads from the existing `_APP_LOG` ring buffer. Sub-projet 7's
`_safe_history_snapshot` pattern applies for safe iteration. No
per-pane state; `serialize` returns `Dict()`.

### `:scope` — visualization with subtype

Subtype lives in the pane state:
```julia
struct ScopePane <: PaneImpl
    subtype::Symbol            # :wave | :amp | :spectrum | :xy | :reservoir-graph | …
    data_ref::Ref{Vector{Float32}}
    aux_state::Dict{Symbol,Any}
end
```
`on_close!` unsubscribes from the OSC scope feed if no other scope
pane is using the same subtype. `serialize` captures
`(subtype, aux_state)`.

Sub-project 10 (or later) can extract `reservoir-graph` into its
own plugin-registered kind. For now it stays as a subtype of
`:scope`.

### `:doc` — DocEntry viewer

Reads `Ressac.lookup_doc(name)` from the sub-project 7 registry.
Renders the body MD with minimal formatting (headers, lists, code
blocks). `serialize` captures the `name` ref so the pane restores
on next session showing the same entry.

```julia
struct DocPane <: PaneImpl
    name::String               # the DocEntry name
    scroll::Int
end
```

## Snippet `panes = [...]` integration

The field was anticipated in sub-project 7 and parsed-ignored.
This sub-project finally gives it meaning.

### Schema

```toml
panes = [
  { kind = "editor", role = "primary", buffer_role = "patterns" },
  { kind = "scope",  target = "reservoir-graph", role = "side", side = "right", ratio = 0.4 },
  { kind = "doc",    ref = "Reservoir.rate_voice", role = "side", side = "bottom", ratio = 0.3 },
]
```

Per-pane fields:
- `kind` (required) — registered pane kind name
- `role` (required) — `"primary"` (one and only one) or `"side"` (zero or more)
- `side` (required for `side` roles) — `"left" | "right" | "top" | "bottom"`
- `ratio` (optional) — float 0..1, fraction of available space; default 0.4
- Kind-specific args (`target` for scope, `ref` for doc, `buffer_role`
  for editor) — passed through to the pane's constructor

### Behavior dispatched by snippet `mode`

- **`mode = "starter"`** → replace the focused workspace:
  1. Clear the current workspace's tree (preserving floats).
  2. Build a new tree with the `primary` pane as the root.
  3. For each `side` in declaration order, split the appropriate
     edge with the requested ratio.
  4. Inject the snippet's Julia content into the primary pane
     (editor receives the full content).
  5. Focus the primary.

- **`mode = "block"`** → compose:
  1. Insert the snippet's Julia content at the cursor in the focused
     editor pane (existing block-insert behavior).
  2. For each `side` pane, check if a pane with the same kind +
     args already exists in the current workspace. If yes, focus it
     and don't duplicate. If no, split the focused pane's parent in
     the requested direction.

### Error handling

- Pane `kind` not registered: warn, skip this entry, continue with
  the rest.
- `ref` or `target` doesn't resolve (e.g. doc entry missing): pane
  opens anyway with body `"(no entry for X)"`.
- All `side` entries fail AND primary fails: log error, do not touch
  the current tree.

## User config — override stack

`~/.config/ressac/config.toml` gains a `[panes]` section:

```toml
[panes.kinds.doc]
default_mode = "float"                 # all doc panes float by default

[panes.kinds.scope]
default_mode = "tile"
default_subtype = "reservoir-graph"

[panes.snippets."reservoir-pop5"]
# Total override of the snippet's panes = [...].
panes = [
  { kind = "editor", role = "primary" },
  { kind = "scope", target = "wave", role = "side", side = "right" },
]
```

Resolution order (last-wins):
1. Default coded in the `PaneImpl` (e.g. `default_mode(::DocPane) = :tile`)
2. Override in the snippet / doc frontmatter
3. Override in `~/.config/ressac/config.toml`

User config is terminal — never cascaded back to a plugin-side
override. Simple, predictable, no cycles possible.

## Keyboard model — zellij-inspired pane mode

The vim-style `<C-w>` prefix doesn't act as a one-shot prefix.
Instead, it ENTERS "pane mode" (zellij convention). A visible
indicator updates the status bar color. Single keys work until
`Esc` or until a single-shot operation completes.

| Mode | Trigger | Keys | Exit |
|---|---|---|---|
| normal | default | full vim editing | — |
| **pane** | `<C-w>` | `s` hsplit · `v` vsplit · `h/j/k/l` nav · `c` close · `w` cycle · `f` toggle tile/float · `t` new tab · `z` zoom · `+/-` resize | `Esc`; auto-exit after a single op unless sticky |
| **resize** | `<C-w>r` | `h/j/k/l` resize directional, repeatable | `Esc` |
| insert | `i` | text input | `Esc` |
| command | `:` | ex commands | `Esc` or `Enter` |

`Tab` while in pane mode → toggle "sticky" (keep pane mode for
multiple operations). Visible "STICKY" indicator. Esc exits sticky
back to normal.

Globally bound (work in any mode):
- `Ctrl-1..9` — jump to workspace N
- `Ctrl-PageUp/PageDown` — prev/next workspace
- `Ctrl-Shift-F` — toggle visibility of ALL floats in the current
  workspace (zellij convention)

Ex commands (scriptable, available from snippets and macros):
```
:split <kind> [args]
:vsplit <kind> [args]
:focus <left|right|up|down|next|prev|<id>>
:close [pane-id]
:resize <left|right|up|down> <delta>
:workspace [new|close|next|prev|<N>|<name>]
:layout save <name>
:layout load <name>
:tile
:float
:zoom
```

## Persistence

### `last_layout.toml` — autosaved on `:q`

`~/.config/ressac/last_layout.toml`:

```toml
[workspaces.0]
name = "live"
focused_pane = 5

[workspaces.0.tree]
type = "container"
direction = "h"
ratios = [0.6, 0.4]

[[workspaces.0.tree.children]]
type = "pane"
kind = "editor"
id = 1
state = { tabs = [{ role = "patterns", name = "main", file_ref = "<path-or-buffer-key>" }], current_tab = 0 }

[[workspaces.0.tree.children]]
type = "container"
direction = "v"
ratios = [0.7, 0.3]

# (nested children…)

[[workspaces.0.floats]]
kind = "doc"
x = 60; y = 10
w = 50; h = 20
state = { name = "SinOsc", scroll = 0 }

[workspaces.1]
name = ""
focused_pane = 2

# (workspace 1 tree…)
```

### Named layouts

`~/.config/ressac/layouts/<name>.toml` — same format. Saved with
`:layout save <name>`, loaded with `:layout load <name>`. Loading a
named layout creates a new workspace (or replaces the current one
based on user prompt).

### Restore failure handling

If `last_layout.toml` doesn't exist (fresh install) OR fails to
parse OR references a kind that no longer exists: warn, fallback to
a single workspace named `""` containing one `:editor` pane.
Existing buffer files on disk are unaffected — the layout file is
purely structural.

## System chrome — placement around the workspace area

```
┌──────────────────────────────────────────────────────────┐
│ [1: live] [2: synth-design] [3:]            mode  | fps  │  ← workspace tab strip + status (1 row)
├──────────────────────────────────────────────────────────┤
│ ?  hint widget — mode-aware key reminders                │  ← sub-project 6 hint widget (1 row)
├──────────────────────────────────────────────────────────┤
│                                                          │
│   workspace area: tiled tree + floats overlaid           │  ← variable height
│                                                          │
├──────────────────────────────────────────────────────────┤
│ sin_osc(freq=440, mul=1, add=0) — Sine oscillator        │  ← livedoc bar (1 row, follows focused pane's cursor)
├──────────────────────────────────────────────────────────┤
│ [INFO] last action log entry…                            │  ← global log tail (1-3 rows; collapses to 0 if a :log pane is present)
└──────────────────────────────────────────────────────────┘
```

- The workspace tab strip is always present, even with one workspace.
- The hint widget stays as it lives today (sub-project 6).
- The workspace area fills whatever's left vertically.
- The livedoc bar attaches to the focused pane (when an editor or
  scope is focused, shows context; when log / doc is focused, shows
  short pane help).
- The global log tail collapses to zero rows if a `:log` pane
  exists in the current workspace — avoids duplication.

## Backward-compatibility migration plan

14 incremental commits, each green-tests-pass before merge:

| # | Step | Outcome |
|---|---|---|
| 1 | Create `pane_interface.jl` (abstract + 12 fns + registry) | Pure additive, no UX change |
| 2 | Create `workspace_manager.jl` (LayoutNode types + Workspace + WorkspaceManager + ops) | Pure additive |
| 3 | Implement `:editor` PaneImpl (extract + unify patterns/synth) | UI still uses old layout path |
| 4 | Implement `:log` PaneImpl | Same |
| 5 | Implement `:doc` PaneImpl | Same |
| 6 | Implement `:scope` PaneImpl (subtype state) | Same |
| 7 | Replace `m.layout_*` + `view()` body with `WorkspaceManager` rendering | Single-workspace single-pane editor — visually identical to today |
| 8 | Implement split / close / nav + C-w pane mode + ex commands | Manual splits work |
| 9 | Implement multi-workspace (Ctrl-1..9 + tab strip + create/destroy) | Workspaces usable |
| 10 | Implement persistence (`last_layout.toml` autosave / restore) | Layouts persist |
| 11 | Implement snippet `panes = [...]` application | "doc à côté when starter" works |
| 12 | Implement user config override stack | UX configurable |
| 13 | Implement floating panes (`:float` toggle + Ctrl-Shift-F) | Floats usable |
| 14 | Remove dead code: `m.layout_*` field declarations, old rect computation in `view()`, modal-trampoline routes that conflict with the new pane model | -300 lines of `tui_app.jl` |

Each step merges to main when its tests pass. Sub-project 9 ships
when 14 is merged. The deferred modals (sub-project 10) are touched
zero times — their current overlay implementation lives in a layer
above the workspace area and renders fine.

## Testing strategy

### Unit (no TUI)

- `LayoutNode` operations: split, close, navigate over synthetic
  trees (~30 assertions: symmetry, idempotence, collapse, navigation
  cycles).
- `WorkspaceManager`: create/destroy workspace, switch, persistence
  round-trip (~20 assertions).
- Registry: register / lookup, conflict, missing-kind handling.
- Snippet `panes = [...]` resolution: 5 cases (starter + block,
  ref valid + invalid, side ordering).
- User config override stack: last-wins assertions.

### Integration (TUI via Tachikoma TestBackend)

- Full cycle: create workspace, split, navigate, close, persist,
  restore — verify rendered Rects match expectation.
- `:starter reservoir-pop5` end-to-end: tree post-application has
  primary + 2 sides at the right ratios.
- `:layout save name` → modify layout → `:layout load name` →
  state matches the save.

### Regression

All 1542 existing tests stay green. Tests that touch `m.layout_*`
migrate to the `WorkspaceManager` API (~10 tests to adapt,
mechanical).

## Risks and mitigations

- **R1 — Tachikoma rendering contract**: Tachikoma's view loop
  expects `view(m::RessacApp, frame)` to draw into the frame. The
  WorkspaceManager must respect the same buffer / clipping rules.
  **Mitigation**: step 7 of the migration plan keeps the `view`
  signature identical — only its internal body changes.

- **R2 — Performance with N panes × 50 fps**: a 20-pane workspace
  rendered 50× per second is 1000 render! calls/sec. Each pane's
  render is isolated (no global state mutation), and the layout
  computation is O(n) over the tree.
  **Mitigation**: measure end of step 11; if a hotspot emerges,
  cache rect computation between frames (the tree changes rarely
  vs the frame rate).

- **R3 — Override stack cycles**: pathological case where user
  config and snippet override each other endlessly.
  **Mitigation**: the model is strictly one-level. User config is
  terminal; it never references "use the snippet's value". No
  recursion possible.

- **R4 — Layout TOML growth**: a workspace with many tabs across
  many panes could produce a large file.
  **Mitigation**: pane state holds file references, not buffer
  content. The patterns buffers are saved via the existing `:w`
  flow; the layout file just points at them.

- **R5 — Snippet panes spec referencing unregistered kind**: e.g.
  the user runs `:starter reservoir-pop5` but the reservoir plugin
  isn't loaded.
  **Mitigation**: warn + skip that pane spec; the rest applies. The
  resulting layout is partial but coherent. Same model as
  sub-project 7's `requires_plugins` check.

- **R6 — Editor unification regressions**: the unified `:editor`
  kind must preserve every behavior of patterns editor AND synth
  editor. Subtle behaviors (eval routing, autocomplete context,
  `T` vs `e` keys) need careful migration.
  **Mitigation**: step 3 ships extensive tests asserting that the
  existing modal interactions (the ~30 keyboard tests in
  `test_modal_helpers.jl` + `test_tui.jl`) still pass with the new
  pane implementation. The role-per-buffer mechanism is unit tested
  separately.

## Acceptance criteria

Sub-project 9 is done when:

1. `WorkspaceManager` replaces `m.layout_*` in `RessacApp`. The
   layout calculation code is removed from `tui_app.jl`'s `view()`.
2. The 4 core kinds (`:editor`, `:log`, `:scope`, `:doc`) are
   registered via `register_pane_kind!` at boot. Each implements
   the mandatory 4 functions plus any necessary optionals.
3. Split + close + navigate work via `<C-w>` pane mode AND ex
   commands. Pane mode is sticky-toggleable via `Tab`.
4. Workspaces are dynamic: `:workspace new <name>` creates,
   `:workspace close` destroys, `Ctrl-1..9` jumps, tab strip is
   rendered at the top.
5. Layout autosave on `:q` to `~/.config/ressac/last_layout.toml`;
   restore at next boot with graceful fallback to single-workspace
   single-pane editor on failure.
6. `:layout save <name>` and `:layout load <name>` are functional;
   named layouts live in `~/.config/ressac/layouts/<name>.toml`.
7. Snippet `panes = [...]` is applied per mode (starter = replace,
   block = compose). User config override stack is honored. Bad
   `panes` entries warn-and-skip without crashing.
8. Floating panes work: `:float` toggle on a focused tile pane,
   `:tile` reverses, `Ctrl-Shift-F` toggles all-floats visibility.
9. 1542 existing tests stay green + ~60 new tests pass (LayoutNode,
   WorkspaceManager, snippet panes, persistence, override stack).
10. Boot time ≤ 250 ms (200 ms baseline from sub-project 7 plus
    ~50 ms permitted for layout restore on a typical session).

## Open questions deferred to sub-project 10

- **Migrate the 6 modals to floating panes**: mixer, browser,
  snippet picker, synth library, sccode, `:guide`. Currently
  overlays. Becomes "floating panes by default" with the registry
  contract.
- **`reservoir-graph` as its own plugin-registered kind**: today a
  `:scope` subtype. Promotes to standalone kind contributed by the
  reservoir plugin's `[julia]` section.
- **Mouse-driven splitting**: drag a border to resize, click a tab
  strip arrow to add a new tab. Today's mouse handling stays
  cursor-only.
- **Workspace search / fuzzy switcher**: `Ctrl-w w` for a
  workspace picker (à la fzf). Lower priority.
- **Layout templates**: ship a few default named layouts with the
  install (`live-perf`, `synth-design`, `debug-scope`) that
  newcomers can `:layout load` to discover the system.
