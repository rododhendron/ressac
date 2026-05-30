# Sub-project 10 — Split-pane UI integration (atomic swap)

Status: approved 2026-05-30.

## Goal

Wire the sub-project 9 infrastructure into the live TUI. After this
sub-project, every UI surface renders via `WorkspaceManager`,
`m.layout_*` is gone, C-w pane mode + Ctrl-N workspaces are bound,
snippet `panes = [...]` actually rebuilds layouts, and `save_layout`
runs on quit. **Atomic swap**: no flag, no parallel paths. The
legacy `view()` body and `m.layout_*` fields are removed in the same
commit set that turns on the new dispatch.

The user's explicit choice for atomic over incremental: avoiding the
millstone of a coexisting legacy is worth the risk concentration. We
mitigate with strong per-task tests and an explicit visual parity
checklist.

## Non-goals

- No new pane kinds beyond the 4 core. Plugin-contributed kinds
  (reservoir-graph as standalone, future spectrum analyzer, etc.)
  remain a follow-up.
- No modal migration. The 6 overlays (mixer, browser, snippet
  picker, synth library, sccode, `:guide`) stay as overlays. They
  become floats in a later sub-project.
- No new ex commands beyond what was already designed in sub-project
  9. We expose what's there; we don't expand the surface.
- No persistence of buffer content in `last_layout.toml`. The
  layout file holds structure only; buffers continue to save via
  the existing `:w` flow.

## Architecture

Three concrete shifts:

1. **`view()` body replacement**. The current ~150-line layout
   computation disappears. The new body computes the workspace area
   between chrome bands, calls `_compute_rects(ws.tree, area)`, and
   dispatches `render!` per leaf. Floats render in `z_order` order
   on top.

2. **Chrome extraction**. The status bar, hint widget, livedoc bar,
   and global log tail become standalone helpers (`_render_status_strip!`,
   `_render_hint_widget!`, `_render_livedoc_row!`,
   `_render_global_log_tail!`) that draw into explicit rows. A new
   `_render_workspace_strip!` lands at the very top.

3. **Each `PaneImpl.render!` reaches visual parity** with the
   existing render code. This means:
   - `EditorPane` reproduces the patterns/synth block-bordered render
     with focus indicator, tab bar (when ≥ 2 tabs), cursor highlight,
     and autocomplete overlay.
   - `LogPane` reproduces the log tail render with scroll offset.
   - `ScopePane` dispatches its `subtype` field through the existing
     `_render_app_scope_*` family.
   - `DocPane` formats the MD body with the existing prose styling
     (current `:doc` log dump shape, but rendered in-pane).

## File structure

**Modified source files:**
- `src/tui_app.jl` — `view()` body replacement, chrome helpers
  extracted, mouse handler rewired, keymap hooks for C-w + Ctrl-N +
  Ctrl-Shift-F, `m.layout_*` fields deleted, save/load hooks on
  quit + boot, snippet apply integration in `_starter_command!`
- `src/pane_editor.jl` — full `render!` + `handle_key!` reproducing
  the patterns/synth editor surface (block borders, tab bar,
  cursor, autocomplete picker render)
- `src/pane_log.jl` — full `render!` + `handle_key!` (scroll)
- `src/pane_doc.jl` — full `render!` + `handle_key!` (scroll)
- `src/pane_scope.jl` — full `render!` dispatching subtypes to the
  existing scope renderers; `on_close!` unsubscribes from OSC

**Modified test files:**
- `test/test_tui.jl` — extend with split + workspace integration tests
  exercising `update!` keystrokes

**Deleted lines (not files):**
- The 5 `m.layout_*` fields in `RessacApp`
- The legacy `view()` body's rect computation (~150 lines)
- Mouse-handler references to `m.layout_*`

## The 8 integration tasks

### T1 — Chrome helpers extraction

Extract `_render_status_strip!`, `_render_hint_widget!`,
`_render_livedoc_row!`, `_render_global_log_tail!` from the current
`view()` body into standalone functions. Each takes `(m, y, area, buf)`
and draws into a single row (or fixed height). The existing `view()`
body still calls them inline; behavior unchanged.

This commit is pure refactor: green tests + visually identical live.
Provides the building blocks for T8.

### T2 — `_render_workspace_strip!`

New function. Renders `[1: live] [2: synth] [3:]` at the top row.
Highlighted entry = `wm.current_idx`. Untitled workspaces show
`[N]`. Truncates if the strip overflows.

Still not called by `view()` — only by tests for now.

### T3 — `EditorPane.render!` to visual parity

Port the existing patterns-editor render path. This includes:
- TK block border with title `PATTERNS` (when role=:patterns) or
  `SYNTH · <name><ext> [<mode>]` (when role=:synth)
- Focus indicator via the block's `focused` arg
- Cursor sync via `_sync_cursor_style!`
- Body render via `TK.render(editor, inner, buf)` against the
  existing `TextEditor` from Tachikoma
- Tab bar (when ≥ 2 tabs) at the top of the inner rect

EditorBuffer holds its own `TextEditor` (Tachikoma type) so the
existing render delegates cleanly.

Add `handle_key!` that routes editing keys to the buffer's editor
+ recognizes `e` (slot eval) when `eval_target = :slot`, `T` (sc
preview) when `eval_target = :sc_eval`.

### T4 — `LogPane.render!`, `DocPane.render!`, `ScopePane.render!`

Three smaller renders, in this order:

- `LogPane.render!`: replicate the log tail rendering. The existing
  `_render_global_log_tail!` from T1 becomes the helper; the pane
  calls it with its own scroll offset state.
- `DocPane.render!`: format the `DocEntry`'s body MD with section
  headers, kwargs list, examples, scrollable.
- `ScopePane.render!`: dispatch through a new
  `_render_scope_subtype!(subtype, rect, buf)` helper that contains
  the same code that `_render_app_scope` runs today. `on_close!`
  calls `_unsubscribe_scope_subtype!`.

### T5 — `view()` body swap

Replace the existing `view(m, frame)` body with the workspace
dispatcher:

```julia
function TK.view(m::RessacApp, f::TK.Frame)
    m.paused && return
    m.tick += 1
    _ensure_default_workspace!(m)
    area = f.area
    buf  = f.buffer

    # Chrome top (3 rows): workspace strip, status, hint.
    _render_workspace_strip!(m, 0, area, buf)
    _render_status_strip!(m, 1, area, buf)
    _render_hint_widget!(m, 2, area, buf)

    # Chrome bottom (2-4 rows): livedoc + global log tail.
    log_h = _global_log_tail_height(m)
    livedoc_y = area.y + area.h - log_h - 1
    log_y = livedoc_y + 1

    # Workspace area = everything between.
    ws_top, ws_height = 3, livedoc_y - 3
    ws_area = (x=area.x, y=ws_top, w=area.w, h=ws_height)
    ws = current_workspace(m.workspaces)
    if ws !== nothing
        rects = _compute_rects(ws.tree, ws_area)
        _render_tree!(ws.tree, rects, buf, m)
        m.floats_hidden || _render_floats!(ws.floats, buf, m)
    end

    _render_livedoc_row!(m, livedoc_y, area, buf)
    _render_global_log_tail!(m, log_y, area, log_h, buf)
end
```

Delete the legacy body. Delete the 5 `m.layout_*` fields. Mouse
handlers rewire in T6.

### T6 — Mouse handler rewire

Find every `m.layout_*` reference in mouse handling (today around
lines 320-380 of `tui_app.jl`). Replace with rect lookup:

```julia
ws = current_workspace(m.workspaces)
ws === nothing && return
ws_area = _workspace_area(f.area)
rects = _compute_rects(ws.tree, ws_area)
for (leaf_id, rect) in rects
    if _in_rect_nt(rect, evt.x, evt.y)
        ws.focused_pane = leaf_id
        leaf = _find_leaf_by_id(ws.tree, leaf_id)
        if leaf !== nothing && !isempty(leaf.tabs)
            handle_mouse!(leaf.tabs[leaf.current_tab], evt)
        end
        return
    end
end
```

The float overlay loop runs first (`z_order` desc) so a click on a
float captures before a tile pane underneath.

### T7 — Keymap integration in `update!`

Wire C-w + Ctrl-N + Ctrl-Shift-F into `update!`:

```julia
function TK.update!(m::RessacApp, evt)
    # Pane mode dispatch first — eats anything in pane mode.
    if _PANE_MODE.active
        evt.key === :escape && (_PANE_MODE.active = false;
                                _PANE_MODE.sticky = false; return)
        evt.key === :tab    && (_PANE_MODE.sticky = !_PANE_MODE.sticky; return)
        evt.key === :char   && _dispatch_pane_mode_key(m.workspaces, evt.char) && return
    end
    # Workspace jump (any mode).
    if evt.key === :ctrl && evt.char in '1':'9'
        cmd_workspace_switch!(m.workspaces, Int(evt.char - '0'))
        return
    end
    # Pane mode entry: C-w in normal mode.
    if m.editor.mode === :normal && evt.key === :ctrl && evt.char == 'w'
        _PANE_MODE.active = true
        return
    end
    # Toggle floats.
    if evt.key === :ctrl_shift && evt.char == 'F'
        m.floats_hidden = !m.floats_hidden
        return
    end
    # …rest of existing update! body
end
```

The exact key-event field names match Tachikoma's `TK.KeyEvent`
shape — adjusted at impl time. `m.floats_hidden::Bool = false` field
added to `RessacApp`.

### T8 — Save/load + snippet apply hooks

Three small integrations:

1. In `_starter_command!`, after looking up the snippet:
   ```julia
   isempty(snip.panes) || apply_snippet_panes!(m.workspaces, snip.panes,
                                               snip.mode;
                                               snippet_name = snip.name)
   ```

2. In `start_live!`, after `RessacApp` construction:
   ```julia
   load_layout!(m.workspaces, _default_layout_path())
   _ensure_default_workspace!(m)
   ```

3. In the `:q` quit handler (find via `grep -n ':q' src/tui_app.jl`):
   ```julia
   save_layout(m.workspaces, _default_layout_path())
   ```

Plus `:layout save <name>` / `:layout load <name>` ex command
registrations using `_named_layout_path(name)`.

## Visual parity checklist

At end of T7, the following MUST be visually identical to
sub-project 9 baseline (i.e. today's pre-swap state):

- [ ] Status bar — left badge + tempo + cycle progress + counters, right mode + focus
- [ ] Patterns block — title `PATTERNS`, right hint when slots are playing, focus indicator
- [ ] Synth block (when open) — title `SYNTH · <name><ext> [<mode>]`, focus indicator, tab strip when ≥ 2 tabs
- [ ] Scope (when `:scope <type>` active) — same height + render as today, all subtypes
- [ ] Livedoc bar — single line, color, position above logs
- [ ] Footer — current behavior preserved
- [ ] Logs — multi-line tail with current scroll
- [ ] Mouse — left-click in any pane area focuses + positions cursor

NEW additions (acceptable visual additions, not regressions):

- Workspace tab strip at the very top (1 row). When only one
  untitled workspace exists, it shows `[1]` — minimal disturbance.

## Mitigations

- **Cumulative TUI regression risk**: each task adds a kind's render
  in isolation BEFORE T5 swaps view. T3, T4 ship their renders but
  the visible UI still uses the legacy path until T5. So a bad
  render is detectable in isolation via unit tests + manual probing
  (call the pane render manually against a TestBackend).

- **Existing render code complexity**: T1's chrome extraction is
  literally `(extract function from middle of view's body, no
  behavior change)`. If it builds + tests pass, it's safe. T3-T4
  are similar but with the constraint of routing through the
  PaneImpl wrapper.

- **Keystroke conflicts** in T7: `Ctrl-w` is potentially used by
  Tachikoma for word-delete in insert mode. We bind only in normal
  mode (`m.editor.mode === :normal`) to avoid this. `Ctrl-Shift-F`
  is new and shouldn't conflict.

- **Mouse handler subtleties**: clicks on the synth tab bar
  currently dispatch to `_click_into_synth_tab!`. After migration,
  tab clicks resolve via the pane's own region. We preserve the
  behavior through `EditorPane.handle_mouse!` reading the tab bar
  rect from its own state.

## Acceptance criteria

Sub-project 10 ships when:

1. `m.layout_patterns` / `m.layout_synth` / `m.layout_synth_tabs` /
   `m.layout_scope` / `m.layout_logs` fields are removed from
   `RessacApp`. `grep -n 'layout_patterns\|layout_synth\|layout_logs\|layout_scope'`
   in `src/` returns empty.
2. `view()` body is the workspace dispatcher (no fixed rect
   computation).
3. `<C-w>s` / `<C-w>v` in normal mode visibly split the active
   workspace; `<C-w>h/j/k/l` navigates; `<C-w>c` closes.
4. `Ctrl-1..9` jumps to numbered workspaces. `Ctrl-PgUp/Dn` cycles.
5. `Ctrl-Shift-F` toggles all-floats visibility.
6. `:starter reservoir-pop5` rebuilds the workspace using the
   snippet's `panes = [...]` spec (editor primary + scope side).
7. `:q` writes `last_layout.toml`; next boot restores it.
8. `:layout save my-perf` + `:layout load my-perf` round-trip.
9. All 1684 sub-project 9 tests stay green + ~25 new integration
   tests pass.
10. Visual parity checklist (above) all items checked off in manual
    smoke test.

## Risks

- **R1 — Cumulative complexity in T3 (EditorPane render)**: porting
  the patterns + synth render is the largest chunk of code in this
  sub-project. **Mitigation**: split T3 into a multi-step task in
  the plan; each step ports one chunk (border, tab bar, body,
  cursor, autocomplete overlay) and re-tests.
- **R2 — Tachikoma editor binding**: Tachikoma's `TextEditor` is
  what we delegate to inside `EditorBuffer`. Ensuring its render
  receives the right rect / focus signal is critical.
  **Mitigation**: T3 includes a unit test that builds an
  `EditorPane` + invokes `render!` against a Tachikoma TestBackend
  and asserts that the inner editor was reached.
- **R3 — Mouse handler subtleties in T6**: clicks on tab bars,
  synth tab switches, scope mode switches were all done by region.
  **Mitigation**: T6 ships tests that simulate clicks at known
  coordinates against a known tree layout.
- **R4 — Keymap conflicts**: `Ctrl-w` is wide-used in editors.
  **Mitigation**: only intercept in normal mode + add a clear test
  that insert-mode `Ctrl-w` does NOT enter pane mode.
- **R5 — Plugin pane kinds in last_layout.toml**: a user's saved
  layout might reference a kind no longer registered after a plugin
  uninstall. **Mitigation**: `load_layout!` already warns + skips on
  unknown kinds (per sub-project 9). The fallback path installs a
  fresh editor pane in place.

## Open questions deferred

- **Per-pane chrome (borders, titles)** — today each pane has a
  block border. After migration, this stays. Future polish:
  borderless mode for dense layouts. Out of scope.
- **Pane resize via mouse drag** — drag a border to resize. Future.
- **Reservoir-graph as its own kind** — currently a `:scope`
  subtype. Promote to plugin-registered kind after reservoir's
  bootstrap.jl gets a `register_pane_kind!` call. Sub-project 11.
- **Modal migration to floats** — mixer, browser, snippet picker,
  synth library, sccode, `:guide`. Sub-project 11 or 12.
