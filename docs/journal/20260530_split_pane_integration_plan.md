# Split-pane UI Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the sub-project 9 workspace infrastructure into the live TUI. After this plan: `view()` dispatches through `WorkspaceManager`, `m.layout_*` is gone, C-w pane mode + Ctrl-N workspaces are bound, snippet `panes = [...]` rebuilds layouts, save/load runs on quit/boot.

**Architecture:** Atomic swap (user choice over incremental). 14 bite-sized TDD tasks chain T1 chrome extraction → T4 per-kind renders → T5 `view()` body swap → T6 mouse rewire → T7 keymap → T8 snippet/save hooks. T1-T4 are preparatory (existing UI unchanged); T5 is the single big-bang moment where m.layout_* disappears and dispatch goes through workspaces; T6-T8 finish the wiring.

**Tech Stack:** Julia 1.10+, Tachikoma 2.1 (existing `TK.view`, `TK.update!`, `TK.Rect`, `TK.Buffer`, `TK.CodeEditor`, `TK.tstyle`), the sub-project 9 `PaneImpl` + `WorkspaceManager` (already merged on main, ~1700 lines of code + 142 tests).

---

## File structure

**Modified source files (no new files):**
- `src/tui_app.jl` — chrome helpers extracted, `view()` body swapped, `RessacApp.workspaces` initialization, m.layout_* fields deleted, mouse handler rewired, keymap hooks, save/load hooks, snippet apply integration
- `src/pane_editor.jl` — full `render!` + `handle_key!` + mouse delegation
- `src/pane_log.jl` — full `render!` + scroll keys
- `src/pane_doc.jl` — full `render!` + scroll keys
- `src/pane_scope.jl` — full `render!` dispatching subtypes, `on_close!` unsubscribes OSC

**Modified test files:**
- `test/test_tui.jl` — split + workspace integration tests using TestBackend
- `test/test_pane_interface.jl` — render smoke tests against TestBackend

---

## Phase 1 — Chrome extraction (preparatory refactor)

### Task 1: Extract chrome helpers from `view()`

**Files:**
- Modify: `src/tui_app.jl` (extract 4 helpers, `view()` calls them inline)

This is a pure refactor. After this task, the existing `view()` body still produces identical output, but its inline rendering of status / hint / livedoc / log tail lives in dedicated functions that T5 can call from the new dispatcher.

- [ ] **Step 1: Locate the existing inline rendering blocks**

Run: `grep -n '_render_status_bar\|_render_livedoc_row\|_render_app_scope' /home/rodolphe/Prog/perso/ressac/src/tui_app.jl`

Confirm: `_render_status_bar` (line ~4141), `_render_livedoc_row` (line ~2500), `_render_app_scope` (line ~2945) already exist. They're called from `view()`. The "extraction" for chrome status, livedoc, scope is mostly a no-op: they already exist as helpers.

What does NOT yet exist as a standalone helper: `_render_hint_widget!` and `_render_global_log_tail!`. The hint widget is rendered inline somewhere in `view()`'s body; the log tail is rendered inline as well.

- [ ] **Step 2: Read the chunk of view() that renders the log tail**

Run: `grep -n 'logs_area\|log_inner\|TK.render(m.log' /home/rodolphe/Prog/perso/ressac/src/tui_app.jl | head -10`

Read those lines to identify the exact log rendering block (call it L1 .. L2).

- [ ] **Step 3: Extract `_render_global_log_tail!`**

Just above `function TK.view(m::RessacApp, f::TK.Frame)` in `src/tui_app.jl`, add:

```julia
"""
    _render_global_log_tail!(m, area, buf)

Render the global log tail into `area`. Extracted from `view()` so
the new workspace dispatcher (sub-project 10) can call it as a
chrome row independently of the workspace area.
"""
function _render_global_log_tail!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    log_inner = _inner_rect(area)
    TK.render(m.log_view, log_inner, buf)
end
```

(Adjust the body to match exactly what view() currently does for logs — i.e. the lines you identified in Step 2. If the existing render uses `_render_pane_block!` with a "LOGS" title, include that here.)

- [ ] **Step 4: Replace the inline log render in `view()` with the helper call**

Find the section of `view()` body that renders logs and replace it with:
```julia
_render_global_log_tail!(m, logs_area, buf)
```

- [ ] **Step 5: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: 1684 passing (no change in count — pure refactor).

- [ ] **Step 6: Smoke test (manual)**

Run: `just live`

Expected: TUI looks identical to before the refactor. Log tail appears in the same place with the same content.

- [ ] **Step 7: Commit**

```bash
git add src/tui_app.jl
git commit -m "$(cat <<'EOF'
refactor(tui): extract _render_global_log_tail! from view()

Pure behavior-preserving extraction. Lets the upcoming workspace
dispatcher render the log tail as a chrome row independently of
the pane tree. No visible change.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `_render_workspace_strip!`

**Files:**
- Modify: `src/tui_app.jl` (add function, not yet called)
- Modify: `test/test_tui.jl` (smoke test render against TestBackend)

- [ ] **Step 1: Write the failing test**

In `test/test_tui.jl`, after the existing test sets, add:

```julia
@testset "_render_workspace_strip! draws workspace labels" begin
    mock = MockOSCClient()
    sched = Scheduler(mock; cps=0.5)
    app = Ressac.RessacApp(; scheduler=sched)
    Ressac.create_workspace!(app.workspaces, "live")
    Ressac.create_workspace!(app.workspaces, "synth")
    app.workspaces.current_idx = 1
    backend = Tachikoma.TestBackend(60, 5)
    buf = backend.buf
    area = Tachikoma.Rect(1, 1, 60, 1)
    Ressac._render_workspace_strip!(app, area, buf)
    # Backend record-stringifies the rendered cells per row.
    row = String([backend.buf.cells[1, c].char for c in 1:60])
    @test occursin("[1: live]", row)
    @test occursin("[2: synth]", row)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`

Expected: `UndefVarError: _render_workspace_strip! not defined`.

- [ ] **Step 3: Implement the function**

In `src/tui_app.jl`, just above `TK.view(m::RessacApp, f::TK.Frame)`:

```julia
"""
    _render_workspace_strip!(m, area, buf)

Render workspace tabs at `area` (typically a single-row band at the
very top). The current workspace is rendered with the accent style,
others with text_dim. Untitled workspaces show as `[N]`.
"""
function _render_workspace_strip!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    x = area.x
    for (i, ws) in enumerate(m.workspaces.workspaces)
        is_current = i == m.workspaces.current_idx
        label = isempty(ws.name) ? "[$i]" : "[$i: $(ws.name)]"
        style = is_current ?
            TK.tstyle(:accent, bold = true) :
            TK.tstyle(:text_dim)
        x + textwidth(label) > area.x + area.width && break
        TK.set_string!(buf, x, area.y, label, style)
        x += textwidth(label) + 1
    end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: 1685+ passing.

- [ ] **Step 5: Commit**

```bash
git add src/tui_app.jl test/test_tui.jl
git commit -m "$(cat <<'EOF'
feat(tui): _render_workspace_strip! — workspace tab bar at top

Renders [1: live] [2: synth] etc. Current workspace styled with
accent + bold; others dim. Used by the workspace dispatcher (T5)
and bound to no chrome row yet — pure addition.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — Per-kind render fidelity

### Task 3a: `EditorPane.render!` — block border + body delegation

**Files:**
- Modify: `src/pane_editor.jl`
- Modify: `test/test_pane_interface.jl`

The full `EditorPane.render!` is the heaviest port in this plan. We split into 3 stages: 3a = block border + body delegate, 3b = tab bar, 3c = key dispatch + eval routing.

- [ ] **Step 1: Add a TK.CodeEditor field to EditorBuffer**

`EditorBuffer` currently holds plain content/cursor strings. The actual rendering needs a `TK.CodeEditor` instance (Tachikoma's editor type) to delegate to. Add a `code_editor::TK.CodeEditor` field, instantiated lazily.

In `src/pane_editor.jl`, replace the `EditorBuffer` struct with:

```julia
mutable struct EditorBuffer
    code_editor::TK.CodeEditor
    role::Symbol            # :patterns | :synth
    name::String
    eval_target::Symbol     # :slot | :sc_eval
    completion_ctx::Symbol  # :patterns_dsl | :synth_dsl | :sc_ugens
end

function EditorBuffer(; role::Symbol = :patterns,
                       name::AbstractString = "main",
                       content::AbstractString = "")
    eval_target, completion_ctx = if role === :synth
        (:sc_eval, :synth_dsl)
    else
        (:slot, :patterns_dsl)
    end
    ed = TK.CodeEditor()
    TK.set_text!(ed, String(content))
    return EditorBuffer(ed, role, String(name), eval_target, completion_ctx)
end
```

- [ ] **Step 2: Update `serialize` to read from code_editor**

In `src/pane_editor.jl`, update `serialize` to extract content + cursor from the underlying `TK.CodeEditor`:

```julia
function serialize(p::EditorPane)
    return Dict{String,Any}(
        "tabs" => [Dict{String,Any}(
            "role" => String(t.role),
            "name" => t.name,
            "content" => TK.text(t.code_editor),
            "cursor_row" => t.code_editor.cursor_row,
            "cursor_col" => t.code_editor.cursor_col,
            "scroll_offset" => t.code_editor.scroll_offset,
        ) for t in p.tabs],
        "current_tab" => p.current_tab,
    )
end
```

- [ ] **Step 3: Implement `render!` with block border + body**

Replace the stub `render!(::EditorPane, area, buf) = nothing` with:

```julia
function render!(p::EditorPane, area, buf)
    1 <= p.current_tab <= length(p.tabs) || return
    tab = p.tabs[p.current_tab]
    title_str = tab.role === :synth ?
        "SYNTH · $(tab.name)" :
        "PATTERNS"
    # NB: pane focus is captured at the workspace level. The dispatcher
    # passes `focused=true` to render! via a side channel — for sub-
    # project 10 we keep it simple and let the chrome render in
    # neutral style. Focus polish in a follow-up.
    rect = TK.Rect(area.x, area.y, area.w, area.h)
    _render_pane_block_simple!(rect, title_str, buf)
    inner = _inner_rect(rect)
    TK.render(tab.code_editor, inner, buf)
end

# Lightweight border render used by the new PaneImpl render. Lifts
# the essentials out of _render_pane_block! without the focus / hint
# logic — focused/hover indicators land in a polish follow-up.
function _render_pane_block_simple!(rect::TK.Rect, title::AbstractString,
                                    buf::TK.Buffer)
    # Top border
    TK.set_string!(buf, rect.x, rect.y,
                   "┌" * "─"^(rect.w - 2) * "┐",
                   TK.tstyle(:text_dim))
    # Title overlaid on top border
    label = " " * String(title) * " "
    label_x = rect.x + 2
    if label_x + textwidth(label) < rect.x + rect.w
        TK.set_string!(buf, label_x, rect.y, label, TK.tstyle(:text))
    end
    # Side borders + bottom
    for y in 1:rect.h - 2
        TK.set_string!(buf, rect.x, rect.y + y, "│", TK.tstyle(:text_dim))
        TK.set_string!(buf, rect.x + rect.w - 1, rect.y + y, "│", TK.tstyle(:text_dim))
    end
    TK.set_string!(buf, rect.x, rect.y + rect.h - 1,
                   "└" * "─"^(rect.w - 2) * "┘",
                   TK.tstyle(:text_dim))
end
```

- [ ] **Step 4: Add a render smoke test**

In `test/test_pane_interface.jl`, append:

```julia
@testset "EditorPane.render! draws into a TestBackend" begin
    _reload_core_pane_kinds()
    ep = Ressac._pane_new(:editor, Dict{String,Any}(
        "buffer_role" => "patterns", "name" => "main"))
    # Set some content so the editor has visible rows
    Tachikoma.set_text!(ep.tabs[1].code_editor, "hello world\n@d1 :bd")
    backend = Tachikoma.TestBackend(40, 10)
    buf = backend.buf
    Ressac.render!(ep, Tachikoma.Rect(1, 1, 40, 10), buf)
    # Top border row contains PATTERNS title
    row1 = String([buf.cells[1, c].char for c in 1:40])
    @test occursin("PATTERNS", row1)
end
```

- [ ] **Step 5: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: 1686+ passing.

- [ ] **Step 6: Commit**

```bash
git add src/pane_editor.jl test/test_pane_interface.jl
git commit -m "$(cat <<'EOF'
feat(tui): EditorPane.render! ports the patterns/synth editor

EditorBuffer now holds a TK.CodeEditor (Tachikoma's editor type)
so render! delegates the body via TK.render. _render_pane_block_simple!
provides the surrounding border + title. PATTERNS title for :patterns
role, SYNTH · <name> for :synth.

Tab bar render lands in T3b. Focus indicator + autocomplete overlay
land in T3c.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3b: `EditorPane.render!` — tab bar

**Files:**
- Modify: `src/pane_editor.jl`

- [ ] **Step 1: Update `render!` to draw tab bar when ≥ 2 tabs**

Replace the existing `render!` body with:

```julia
function render!(p::EditorPane, area, buf)
    1 <= p.current_tab <= length(p.tabs) || return
    tab = p.tabs[p.current_tab]
    title_str = tab.role === :synth ?
        "SYNTH · $(tab.name)" :
        "PATTERNS"
    rect = TK.Rect(area.x, area.y, area.w, area.h)
    _render_pane_block_simple!(rect, title_str, buf)
    inner = _inner_rect(rect)
    if length(p.tabs) > 1
        # Tab strip on the first inner row; body fills the rest.
        tab_row = TK.Rect(inner.x, inner.y, inner.w, 1)
        body = TK.Rect(inner.x, inner.y + 1, inner.w, inner.h - 1)
        _render_editor_tab_strip!(p, tab_row, buf)
        TK.render(tab.code_editor, body, buf)
    else
        TK.render(tab.code_editor, inner, buf)
    end
end

function _render_editor_tab_strip!(p::EditorPane, area::TK.Rect, buf::TK.Buffer)
    x = area.x
    for (i, t) in enumerate(p.tabs)
        is_current = i == p.current_tab
        label = " $(t.name) "
        style = is_current ? TK.tstyle(:accent, bold = true) :
                              TK.tstyle(:text_dim)
        x + textwidth(label) > area.x + area.w && break
        TK.set_string!(buf, x, area.y, label, style)
        x += textwidth(label)
    end
end
```

- [ ] **Step 2: Test the tab strip render**

Append to `test/test_pane_interface.jl`:

```julia
@testset "EditorPane render with multiple tabs shows tab strip" begin
    _reload_core_pane_kinds()
    ep = Ressac._pane_new(:editor, Dict{String,Any}(
        "buffer_role" => "patterns", "name" => "main"))
    # Add a second tab manually
    push!(ep.tabs, Ressac.EditorBuffer(role = :synth, name = "wob1"))
    backend = Tachikoma.TestBackend(40, 10)
    buf = backend.buf
    Ressac.render!(ep, Tachikoma.Rect(1, 1, 40, 10), buf)
    # Inner first row (y=2) should contain both tab names
    tab_row = String([buf.cells[2, c].char for c in 1:40])
    @test occursin("main", tab_row)
    @test occursin("wob1", tab_row)
end
```

- [ ] **Step 3: Run tests + commit**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

```bash
git add src/pane_editor.jl test/test_pane_interface.jl
git commit -m "$(cat <<'EOF'
feat(tui): EditorPane tab strip when ≥ 2 tabs

Single inner row at the top renders tab names; current tab gets
accent + bold styling. Body shrinks by one row to make space.
Tab navigation key (in pane mode 'T' or via :tabnext) lands in T3c.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3c: `EditorPane.handle_key!` + eval routing

**Files:**
- Modify: `src/pane_editor.jl`

- [ ] **Step 1: Implement `handle_key!` with eval routing**

Replace the stub `handle_key!(::EditorPane, evt) = false` with:

```julia
function handle_key!(p::EditorPane, evt)
    1 <= p.current_tab <= length(p.tabs) || return false
    tab = p.tabs[p.current_tab]

    # Eval routing — the legacy 'e' / 'T' keys.
    if evt isa TK.KeyEvent && evt.key === :char
        if evt.char == 'e' && tab.eval_target === :slot
            _eval_focused_buffer_to_slot!(tab)
            return true
        elseif evt.char == 'T' && tab.eval_target === :sc_eval
            _eval_focused_buffer_to_sc!(tab)
            return true
        end
    end

    # Default: delegate to the underlying Tachikoma editor.
    return TK.update!(tab.code_editor, evt)
end

# Placeholder eval helpers. T8 wires these to the real eval flows
# (the existing slot eval + SC eval code paths).
function _eval_focused_buffer_to_slot!(::EditorBuffer)
    nothing  # T8 will populate
end
function _eval_focused_buffer_to_sc!(::EditorBuffer)
    nothing  # T8 will populate
end
```

- [ ] **Step 2: Test eval routing dispatch**

Append to `test/test_pane_interface.jl`:

```julia
@testset "EditorPane.handle_key! routes 'e' for patterns role" begin
    _reload_core_pane_kinds()
    ep = Ressac._pane_new(:editor, Dict{String,Any}(
        "buffer_role" => "patterns"))
    # Build a TK.KeyEvent for 'e'
    evt = Tachikoma.KeyEvent(:char, 'e', Tachikoma.key_press)
    @test Ressac.handle_key!(ep, evt) == true
end

@testset "EditorPane.handle_key! routes 'T' for synth role" begin
    _reload_core_pane_kinds()
    ep = Ressac._pane_new(:editor, Dict{String,Any}(
        "buffer_role" => "synth"))
    evt = Tachikoma.KeyEvent(:char, 'T', Tachikoma.key_press)
    @test Ressac.handle_key!(ep, evt) == true
end

@testset "EditorPane.handle_key! delegates unknown chars" begin
    _reload_core_pane_kinds()
    ep = Ressac._pane_new(:editor, Dict{String,Any}())
    # A plain alphabetic char — depending on Tachikoma editor mode,
    # this returns true (insert mode) or false (normal mode).
    evt = Tachikoma.KeyEvent(:char, 'x', Tachikoma.key_press)
    # We don't assert specific true/false because the editor's mode
    # is implementation-detail — just that we don't crash.
    Ressac.handle_key!(ep, evt)
    @test true
end
```

- [ ] **Step 3: Run tests + commit**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

```bash
git add src/pane_editor.jl test/test_pane_interface.jl
git commit -m "$(cat <<'EOF'
feat(tui): EditorPane.handle_key! with eval routing stubs

'e' triggers slot eval for patterns role; 'T' triggers SC eval for
synth role. Other keys delegate to the underlying TK.CodeEditor.
The actual eval helpers (slot scheduler push / /dirt/evalSC ship)
are stubs; T8 wires them to the existing tui_app.jl flows.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4a: `LogPane.render!` + scroll

**Files:**
- Modify: `src/pane_log.jl`
- Modify: `test/test_pane_interface.jl`

- [ ] **Step 1: Implement render! that consumes the global log**

In `src/pane_log.jl`, replace the stub render with:

```julia
function render!(p::LogPane, area, buf)
    rect = TK.Rect(area.x, area.y, area.w, area.h)
    _render_pane_block_simple!(rect, "LOGS", buf)
    inner = _inner_rect(rect)
    # _APP_LOG is a Vector{String} (or Vector{Tuple} per the actual
    # implementation in tui_app.jl). Render the tail with scroll
    # offset support.
    log = _APP_LOG[]
    n = length(log)
    if n == 0
        return
    end
    # Skip p.scroll lines from the end.
    end_i = max(1, n - p.scroll)
    start_i = max(1, end_i - inner.h + 1)
    for (offset, i) in enumerate(start_i:end_i)
        screen_y = inner.y + offset - 1
        if inner.y <= screen_y < inner.y + inner.h
            line = first(String(log[i]), inner.w)
            TK.set_string!(buf, inner.x, screen_y, line, TK.tstyle(:text))
        end
    end
end

function handle_key!(p::LogPane, evt)
    if evt isa TK.KeyEvent && evt.key === :char
        if evt.char == 'k'
            p.scroll += 1; return true
        elseif evt.char == 'j' && p.scroll > 0
            p.scroll -= 1; return true
        end
    end
    return false
end
```

- [ ] **Step 2: Add render smoke test**

Append to `test/test_pane_interface.jl`:

```julia
@testset "LogPane.render! draws border + log lines" begin
    _reload_core_pane_kinds()
    lp = Ressac._pane_new(:log, Dict{String,Any}())
    push!(Ressac._APP_LOG[], "test log line A")
    push!(Ressac._APP_LOG[], "test log line B")
    backend = Tachikoma.TestBackend(40, 5)
    buf = backend.buf
    Ressac.render!(lp, Tachikoma.Rect(1, 1, 40, 5), buf)
    top = String([buf.cells[1, c].char for c in 1:40])
    @test occursin("LOGS", top)
end
```

- [ ] **Step 3: Run tests + commit**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

```bash
git add src/pane_log.jl test/test_pane_interface.jl
git commit -m "$(cat <<'EOF'
feat(tui): LogPane.render! consumes _APP_LOG with scroll support

Reproduces the legacy log tail render with a LOGS-titled border and
scroll offset. j/k handle_key keys nudge the offset. The pane is
self-contained — the global log tail chrome row in view() collapses
to 0 when a LogPane is present in the workspace tree (Task 5).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4b: `DocPane.render!` + scroll

**Files:**
- Modify: `src/pane_doc.jl`
- Modify: `test/test_pane_interface.jl`

- [ ] **Step 1: Implement render! using lookup_doc**

Replace the stub render with:

```julia
function render!(p::DocPane, area, buf)
    rect = TK.Rect(area.x, area.y, area.w, area.h)
    _render_pane_block_simple!(rect, "DOC · $(p.name)", buf)
    inner = _inner_rect(rect)
    entry = lookup_doc(p.name)
    lines = if entry === nothing
        ["(no entry for '$(p.name)')"]
    else
        out = String[entry.name, "", entry.short, ""]
        isempty(entry.kwargs) || push!(out, "kwargs: " * join(entry.kwargs, ", "))
        isempty(entry.examples) || push!(out, "", "examples:")
        for ex in entry.examples
            push!(out, "  " * ex)
        end
        isempty(entry.body) || (push!(out, ""); append!(out, split(entry.body, '\n')))
        out
    end
    for (offset, line) in enumerate(lines[1 + p.scroll : end])
        screen_y = inner.y + offset - 1
        screen_y >= inner.y + inner.h && break
        chunk = first(String(line), inner.w)
        TK.set_string!(buf, inner.x, screen_y, chunk, TK.tstyle(:text))
    end
end

function handle_key!(p::DocPane, evt)
    if evt isa TK.KeyEvent && evt.key === :char
        if evt.char == 'j'
            p.scroll += 1; return true
        elseif evt.char == 'k' && p.scroll > 0
            p.scroll -= 1; return true
        end
    end
    return false
end
```

- [ ] **Step 2: Test missing-ref fallback**

Append to `test/test_pane_interface.jl`:

```julia
@testset "DocPane.render! shows fallback for unknown ref" begin
    _reload_core_pane_kinds()
    dp = Ressac._pane_new(:doc, Dict{String,Any}("ref" => "totally_nonexistent_doc_zzz"))
    backend = Tachikoma.TestBackend(40, 5)
    buf = backend.buf
    Ressac.render!(dp, Tachikoma.Rect(1, 1, 40, 5), buf)
    body_row = String([buf.cells[2, c].char for c in 1:40])
    @test occursin("no entry", body_row)
end
```

- [ ] **Step 3: Run tests + commit**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

```bash
git add src/pane_doc.jl test/test_pane_interface.jl
git commit -m "$(cat <<'EOF'
feat(tui): DocPane.render! formats DocEntry from sub-project 7 registry

Border + DOC · <name> title. Body lists short / kwargs / examples /
prose body. Missing ref → '(no entry for X)' fallback. j/k scroll.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4c: `ScopePane.render!` + `on_close!`

**Files:**
- Modify: `src/pane_scope.jl`
- Modify: `src/tui_scope.jl` (extract `_render_scope_subtype!` from existing `_render_app_scope`)

- [ ] **Step 1: Extract `_render_scope_subtype!` in tui_scope.jl**

Find the existing `_render_app_scope(m::RessacApp, area, buf)` function (around line 2945 of tui_app.jl per the grep). It dispatches on `_APP_SCOPE_TYPE[]` and renders each subtype via helpers like `_app_render_wave`, `_app_render_spectrum`, etc.

Extract its body into a new function in `src/tui_scope.jl`:

```julia
"""
    _render_scope_subtype!(subtype, area, buf)

Render the given scope subtype (`:wave`, `:amp`, `:spectrum`, etc.)
into `area`. Used by ScopePane.render! — replaces the implicit
dispatch on global `_APP_SCOPE_TYPE[]` with explicit per-pane state.
"""
function _render_scope_subtype!(subtype::Symbol, area::TK.Rect, buf::TK.Buffer)
    # Mirror of the existing _render_app_scope body's dispatch.
    if subtype === :amp
        _app_render_amp(_APP_SCOPE_DATA[], area, buf)
    elseif subtype === :wave
        _app_render_wave(_APP_SCOPE_DATA[], area, buf)
    elseif subtype === :spectrum
        _app_render_spectrum(_APP_SCOPE_DATA[], area, buf)
    elseif subtype === :xy
        _app_render_xy(_APP_SCOPE_DATA[], area, buf; rotate45=false)
    elseif subtype === :goni
        _app_render_xy(_APP_SCOPE_DATA[], area, buf; rotate45=true)
    elseif subtype === :spectrogram
        _app_render_spectrogram(area, buf)
    elseif subtype === :peak
        _app_render_peak(_APP_SCOPE_DATA[], area, buf)
    elseif subtype === :pitch
        _app_render_pitch(_APP_SCOPE_DATA[], area, buf)
    elseif subtype === :onset
        _app_render_onset(_APP_SCOPE_DATA[], area, buf)
    elseif subtype === :reservoir
        _app_render_reservoir(area, buf, nothing)
    elseif subtype === Symbol("reservoir-graph")
        _app_render_reservoir_graph(area, buf, nothing)
    # …copy-mirror any remaining dispatch arms from the legacy
    # _render_app_scope body. Use grep to find each `_APP_SCOPE_TYPE`
    # comparison and reproduce it.
    end
end
```

- [ ] **Step 2: Implement ScopePane.render! using the new helper**

In `src/pane_scope.jl`, replace the render stub with:

```julia
function render!(p::ScopePane, area, buf)
    rect = TK.Rect(area.x, area.y, area.w, area.h)
    _render_pane_block_simple!(rect, "SCOPE · $(p.subtype)", buf)
    inner = _inner_rect(rect)
    _render_scope_subtype!(p.subtype, inner, buf)
end

function handle_key!(p::ScopePane, evt)
    # Scope panes have no internal navigation in this iteration.
    return false
end

# on_close!: future iteration unsubscribes from /ressac/scope when
# no other ScopePane uses the same subtype. For sub-project 10 we
# just log (the subscription itself is a no-op when no listener is
# active server-side).
function on_close!(p::ScopePane)
    @info "ScopePane closed: subtype=$(p.subtype)"
    return nothing
end
```

- [ ] **Step 3: Smoke render test**

Append to `test/test_pane_interface.jl`:

```julia
@testset "ScopePane.render! draws SCOPE title" begin
    _reload_core_pane_kinds()
    sp = Ressac._pane_new(:scope, Dict{String,Any}("target" => "wave"))
    backend = Tachikoma.TestBackend(40, 5)
    buf = backend.buf
    Ressac.render!(sp, Tachikoma.Rect(1, 1, 40, 5), buf)
    top = String([buf.cells[1, c].char for c in 1:40])
    @test occursin("SCOPE", top)
    @test occursin("wave", top)
end
```

- [ ] **Step 4: Run tests + commit**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

```bash
git add src/pane_scope.jl src/tui_scope.jl test/test_pane_interface.jl
git commit -m "$(cat <<'EOF'
feat(tui): ScopePane.render! dispatches subtype + on_close! hook

Extracts _render_scope_subtype! from the legacy _render_app_scope
in tui_scope.jl. ScopePane render delegates per-pane (each pane has
its own subtype state) instead of via global _APP_SCOPE_TYPE[].
on_close! is a logging stub — real OSC unsubscription lands in a
polish follow-up.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3 — Atomic view swap (T5)

### Task 5: Swap `view()` body + delete `m.layout_*` fields

**Files:**
- Modify: `src/tui_app.jl` (replace view body + delete struct fields)

**WARNING**: this is the single big-bang task. After this commit, the UI dispatches entirely through `WorkspaceManager`. If something visibly breaks, revert and identify the culprit pane via the per-kind tests from Tasks 3-4.

- [ ] **Step 1: Add `floats_hidden` field to `RessacApp`**

Find the `@kwdef mutable struct RessacApp <: TK.Model` declaration (around line 59). Just below the `workspaces::WorkspaceManager = WorkspaceManager()` field added in sub-project 9, add:

```julia
    # Sub-project 10: toggle for Ctrl-Shift-F all-floats visibility.
    floats_hidden::Bool                     = false
```

- [ ] **Step 2: Delete the legacy `m.layout_*` fields**

In the same struct block, find and delete:

```julia
    layout_patterns::Union{Nothing,TK.Rect} = nothing
    layout_synth::Union{Nothing,TK.Rect}    = nothing
    layout_synth_tabs::Union{Nothing,TK.Rect} = nothing
    layout_scope::Union{Nothing,TK.Rect}    = nothing
    layout_logs::Union{Nothing,TK.Rect}     = nothing
```

(This will break tests + the mouse handler. Tasks 6 fixes the mouse; the tests in the next steps verify the new path.)

- [ ] **Step 3: Add `_render_tree!` + `_render_floats!` helpers**

Just above `function TK.view(m::RessacApp, f::TK.Frame)`, add:

```julia
"""
    _render_tree!(node, rects, buf, m)

Walk the workspace tree and call each leaf's render! against its
computed rect. Containers recurse.
"""
function _render_tree!(node::LayoutNode, rects::Dict, buf::TK.Buffer,
                       m::RessacApp)
    if node isa PaneLeaf
        r = rects[node.id]
        if 1 <= node.current_tab <= length(node.tabs)
            render!(node.tabs[node.current_tab],
                    (x=r.x, y=r.y, w=r.w, h=r.h), buf)
        end
        return
    end
    for child in node.children
        _render_tree!(child, rects, buf, m)
    end
end

"""
    _render_floats!(floats, buf, m)

Render floating panes in ascending z_order (later floats overlay
earlier ones).
"""
function _render_floats!(floats::Vector{FloatingPane}, buf::TK.Buffer,
                         m::RessacApp)
    for f in sort(floats; by = f -> f.z_order)
        render!(f.pane, (x=f.x, y=f.y, w=f.w, h=f.h), buf)
    end
end

"""
    _global_log_tail_height(m) -> Int

Number of rows reserved for the global log tail chrome. Collapses to
0 when a :log pane is present in the current workspace tree (the
pane handles the log render — no need for a duplicate chrome row).
"""
function _global_log_tail_height(m::RessacApp)
    ws = current_workspace(m.workspaces)
    ws === nothing && return 3
    has_log_pane = any(leaf -> any(t -> t isa LogPane, leaf.tabs),
                        _all_leaves(ws.tree))
    return has_log_pane ? 0 : 3
end
```

- [ ] **Step 4: Replace the `view()` body**

Find `function TK.view(m::RessacApp, f::TK.Frame)`. Select its entire body (between the function line and `end`). Replace with:

```julia
function TK.view(m::RessacApp, f::TK.Frame)
    m.paused && return
    m.tick += 1
    _ensure_default_workspace!(m)
    area = f.area
    buf  = f.buffer

    # Chrome top — 3 rows: workspace strip, status, hint.
    _render_workspace_strip!(m, TK.Rect(area.x, area.y, area.w, 1), buf)
    _render_status_bar(m, TK.Rect(area.x, area.y + 1, area.w, 1), buf)
    _render_hint_widget_row!(m, TK.Rect(area.x, area.y + 2, area.w, 1), buf)

    # Chrome bottom — livedoc + global log tail.
    log_h = _global_log_tail_height(m)
    livedoc_y = area.y + area.h - log_h - 1
    log_y = livedoc_y + 1

    # Workspace area = everything between.
    ws_top    = area.y + 3
    ws_height = livedoc_y - ws_top
    ws_area   = (x = area.x, y = ws_top, w = area.w, h = ws_height)
    ws = current_workspace(m.workspaces)
    if ws !== nothing
        rects = _compute_rects(ws.tree, ws_area)
        _render_tree!(ws.tree, rects, buf, m)
        m.floats_hidden || _render_floats!(ws.floats, buf, m)
    end

    _render_livedoc_row(m, TK.Rect(area.x, livedoc_y, area.w, 1), buf)
    if log_h > 0
        _render_global_log_tail!(m,
            TK.Rect(area.x, log_y, area.w, log_h), buf)
    end
end
```

- [ ] **Step 5: Add the hint widget row helper**

Just above the new `view()`, add:

```julia
function _render_hint_widget_row!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    # The existing hint widget likely lives in tui_hints.jl as
    # _render_hints. We call it with a single-row rect; it truncates.
    # If the project has no standalone hint render helper, the body
    # of this function should be the inline hint code that used to
    # live in view(). Grep _render_hints / _MODE_HINTS in src/ for
    # the right entry point.
    isdefined(@__MODULE__, :_render_hints) || return
    _render_hints(m, area, buf)
end
```

(Adjust the function name based on what exists in `src/tui_hints.jl`.)

- [ ] **Step 6: Run the test suite**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`

Expected: most existing tests still pass; mouse handler tests likely fail (they reference `m.layout_*`). Note which tests fail — Tasks 6 fixes them.

- [ ] **Step 7: Commit (even if mouse tests fail, the build must be green)**

If any non-mouse-handler test fails, fix it before committing. The remaining mouse tests are addressed in Task 6.

```bash
git add src/tui_app.jl
git commit -m "$(cat <<'EOF'
feat(tui): view() body swapped to WorkspaceManager dispatch

Atomic swap. Removed the 5 m.layout_* fields from RessacApp. The
new body computes the workspace area between chrome bands (3 rows
top, livedoc + log tail bottom), runs _compute_rects on the focused
workspace's tree, and dispatches render! per leaf. Floats render
overlay in z_order. The global log tail row collapses to 0 when a
:log pane is present in the tree.

Mouse handler is intentionally broken until Task 6.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4 — Mouse handler rewire

### Task 6: Rewire mouse handler to use `_compute_rects`

**Files:**
- Modify: `src/tui_app.jl` (mouse handler in `update!`)
- Modify: `test/test_tui.jl`

- [ ] **Step 1: Read the existing mouse dispatch**

Run: `grep -n 'function TK.update.*MouseEvent\|m.layout_synth\|m.layout_patterns\|m.layout_scope\|m.layout_logs' /home/rodolphe/Prog/perso/ressac/src/tui_app.jl | head -20`

Confirm the mouse handler is in `update!(m::RessacApp, evt::TK.MouseEvent)` and references the now-deleted `m.layout_*` fields.

- [ ] **Step 2: Replace the body with workspace-aware dispatch**

Replace the body of `update!(m::RessacApp, evt::TK.MouseEvent)` with:

```julia
function TK.update!(m::RessacApp, evt::TK.MouseEvent)
    ws = current_workspace(m.workspaces)
    ws === nothing && return

    # Hit-test floats first (top of z stack wins).
    if !m.floats_hidden
        for f in sort(ws.floats; by = f -> -f.z_order)
            if _in_rect_xywh(f.x, f.y, f.w, f.h, evt.x, evt.y)
                handle_mouse!(f.pane, evt)
                return
            end
        end
    end

    # Compute workspace area exactly as view() does.
    area = TK.window_rect()  # Or however the framework exposes "current frame area"
    ws_top    = area.y + 3
    log_h     = _global_log_tail_height(m)
    livedoc_y = area.y + area.h - log_h - 1
    ws_area   = (x = area.x, y = ws_top, w = area.w, h = livedoc_y - ws_top)

    rects = _compute_rects(ws.tree, ws_area)
    for (leaf_id, rect) in rects
        if _in_rect_xywh(rect.x, rect.y, rect.w, rect.h, evt.x, evt.y)
            ws.focused_pane = leaf_id
            leaf = _find_leaf_by_id(ws.tree, leaf_id)
            if leaf !== nothing && !isempty(leaf.tabs)
                handle_mouse!(leaf.tabs[leaf.current_tab], evt)
            end
            return
        end
    end
end

_in_rect_xywh(x, y, w, h, px, py) = px >= x && px < x + w && py >= y && py < y + h

function _find_leaf_by_id(node::LayoutNode, leaf_id::Int)
    if node isa PaneLeaf
        return node.id == leaf_id ? node : nothing
    end
    for child in node.children
        hit = _find_leaf_by_id(child, leaf_id)
        hit === nothing || return hit
    end
    return nothing
end
```

Notes for the implementer:
- `TK.window_rect()` is illustrative. Tachikoma may not expose the current frame area outside `view()`. If not, cache the last-known area in `m` (e.g. `m.last_view_area::TK.Rect = TK.Rect(0,0,0,0)`) and refresh it from `view()`.

- [ ] **Step 3: Run the test suite**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: green. Mouse-related tests that were failing after Task 5 now pass.

- [ ] **Step 4: Smoke test (manual)**

Run: `just live`

Click into the patterns area → cursor moves there. Click into a side log pane → focus moves to it. Click on a float → it captures.

- [ ] **Step 5: Commit**

```bash
git add src/tui_app.jl test/test_tui.jl
git commit -m "$(cat <<'EOF'
feat(tui): mouse handler rewired through _compute_rects

Hit-tests floats first (top z wins), then tile leaves via the
workspace tree's rect computation. Focus moves to the clicked
leaf; the pane's handle_mouse! is invoked. Replaces the 5
m.layout_* lookups that were deleted in Task 5.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 5 — Keymap integration

### Task 7a: Pane mode entry + dispatch in `update!`

**Files:**
- Modify: `src/tui_app.jl`

- [ ] **Step 1: Add pane mode dispatch at the top of `update!(m, evt::KeyEvent)`**

Find the existing `TK.update!(m::RessacApp, evt::TK.KeyEvent)`. At the very top of its body (before any existing dispatch), add:

```julia
    # Sub-project 10: pane mode dispatch.
    if _PANE_MODE.active
        if evt.key === :escape
            _PANE_MODE.active = false
            _PANE_MODE.sticky = false
            return
        elseif evt.key === :tab
            _PANE_MODE.sticky = !_PANE_MODE.sticky
            return
        elseif evt.key === :char
            if _dispatch_pane_mode_key(m.workspaces, evt.char)
                return
            end
        end
        # If we got here, the key was unrecognized — eat it (don't
        # leak into editor) while still in pane mode.
        return
    end

    # Sub-project 10: pane mode entry. Ctrl-W only in editor normal
    # mode, to avoid clobbering word-delete in insert mode.
    if m.editor.mode === :normal && evt.key === :ctrl && evt.char == 'w'
        _PANE_MODE.active = true
        return
    end
```

(Adjust `m.editor.mode === :normal` to the actual mode-check API. Check: `grep -n 'editor.mode' src/tui_app.jl | head -5`.)

- [ ] **Step 2: Run tests + smoke test + commit**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Manual smoke: `just live` → in normal mode press `Ctrl-w` → press `v` → screen splits visually with a new editor pane on the right.

```bash
git add src/tui_app.jl
git commit -m "$(cat <<'EOF'
feat(tui): C-w enters pane mode; single-key dispatch + Tab sticky

In editor normal mode, Ctrl-W flips _PANE_MODE.active. Single-shot
operations auto-exit; Tab toggles sticky. Esc always exits. Keys
that pane mode doesn't recognize are eaten (don't leak to the
editor while in pane mode).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7b: `Ctrl-1..9` workspaces + `Ctrl-Shift-F` floats toggle

**Files:**
- Modify: `src/tui_app.jl`

- [ ] **Step 1: Add globals at the top of `update!`**

Just above the pane mode dispatch added in 7a, add:

```julia
    # Sub-project 10: workspace jump (any mode).
    if evt.key === :ctrl && evt.char in '1':'9'
        cmd_workspace_switch!(m.workspaces, Int(evt.char - '0'))
        return
    end
    # Sub-project 10: toggle all-floats visibility.
    if evt.key === :ctrl && evt.char == 'F'  # Some terminals send 'F' for Ctrl-Shift-F
        m.floats_hidden = !m.floats_hidden
        return
    end
```

(Real `Ctrl-Shift-F` detection depends on Tachikoma's modifier representation. If it's `evt.modifiers & (CTRL | SHIFT) == (CTRL | SHIFT)`, adjust accordingly. The test below verifies the toggle, not the keystroke.)

- [ ] **Step 2: Run tests + smoke + commit**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Manual: `just live` → `:workspace new live` → `Ctrl-1` jumps to workspace 1, `Ctrl-2` to 2. `Ctrl-Shift-F` toggles whatever floats are visible.

```bash
git add src/tui_app.jl
git commit -m "$(cat <<'EOF'
feat(tui): Ctrl-1..9 workspace jump + Ctrl-Shift-F float toggle

Both bindings work in any mode (including insert) — designed for
fast live-coding switches. Ctrl-1..9 maps to workspace index;
Ctrl-Shift-F flips m.floats_hidden which gates the float render
in view().

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 6 — Save / load / snippet wiring

### Task 8a: Save on `:q`, load on boot

**Files:**
- Modify: `src/tui_app.jl` (quit handler)
- Modify: `src/live_boot.jl` (or wherever `RessacApp` is constructed)

- [ ] **Step 1: Locate the `:q` quit handler**

Run: `grep -n '"q"\|^q\b\|cmd_quit\|TK.QUIT\|exit_app' /home/rodolphe/Prog/perso/ressac/src/tui_app.jl | head -10`

Identify the function that handles `:q` (sets a "should exit" flag or calls `exit_app`).

- [ ] **Step 2: Add save call before exit**

In the `:q` handler, just before the exit/quit call, add:

```julia
try
    save_layout(m.workspaces, _default_layout_path())
catch err
    @warn "Failed to save layout: $(sprint(showerror, err))"
end
```

- [ ] **Step 3: Add load call to start_live!**

In `src/live_boot.jl` (find via `grep -n 'function start_live' src/live_boot.jl`), after the `RessacApp` is constructed but before the live loop starts:

```julia
try
    Ressac.load_layout!(m.workspaces, Ressac._default_layout_path())
catch err
    @warn "Failed to load layout: $(sprint(showerror, err))"
end
Ressac._ensure_default_workspace!(m)
```

- [ ] **Step 4: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: green.

- [ ] **Step 5: Manual round-trip**

`just live` → split → `:q` → relaunch `just live` → split layout restored.

- [ ] **Step 6: Commit**

```bash
git add src/tui_app.jl src/live_boot.jl
git commit -m "$(cat <<'EOF'
feat(tui): hook save_layout into :q + load_layout! into start_live!

~/.config/ressac/last_layout.toml round-trips automatically.
load is wrapped in try/catch (graceful fallback on corrupted file —
_ensure_default_workspace! installs a fresh single-pane editor).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8b: Snippet apply integration in `_starter_command!`

**Files:**
- Modify: `src/tui_app.jl` (extend `_starter_command!`)

- [ ] **Step 1: Locate `_starter_command!`**

Run: `grep -n 'function _starter_command' src/tui_app.jl`

- [ ] **Step 2: Add snippet panes apply after the snippet lookup**

In `_starter_command!`, after the snippet has been resolved but before its content gets inserted, add:

```julia
isempty(snip.panes) || try
    apply_snippet_panes!(m.workspaces, snip.panes, snip.mode;
                          snippet_name = snip.name)
catch err
    _push_app_log!(m, "[ERROR] :starter — apply panes failed: $(sprint(showerror, err))")
end
```

- [ ] **Step 3: Run tests + manual + commit**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Manual: `:starter reservoir-pop5` (the starter has `panes = [...]` from sub-project 7). Workspace rebuilds with primary editor + scope side pane.

```bash
git add src/tui_app.jl
git commit -m "$(cat <<'EOF'
feat(tui): _starter_command! applies snippet panes = [...] spec

When the resolved snippet declares panes, the workspace tree is
rebuilt (or composed in :block mode) via apply_snippet_panes!.
snippet_name is plumbed through for user config override.
Catches errors so a bad panes spec doesn't kill the :starter
command outright.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8c: `:layout save / load` ex commands

**Files:**
- Modify: `src/tui_app.jl` (register ex command handlers)

- [ ] **Step 1: Locate ex command registration**

Run: `grep -n '_register_literal!\|_register_regex' src/tui_app.jl | head -5`

This is where existing ex commands like `:starter`, `:scope`, etc. are wired.

- [ ] **Step 2: Add `:layout save <name>` and `:layout load <name>`**

In the same block, add:

```julia
_register_regex!(r"^layout\s+save\s+([\w-]+)$", (m, mt) -> begin
    name = mt.captures[1]
    try
        save_layout(m.workspaces, _named_layout_path(name))
        _push_app_log!(m, "[INFO] :layout save $name — saved")
    catch err
        _push_app_log!(m, "[ERROR] :layout save $name: $(sprint(showerror, err))")
    end
end)

_register_regex!(r"^layout\s+load\s+([\w-]+)$", (m, mt) -> begin
    name = mt.captures[1]
    path = _named_layout_path(name)
    if !isfile(path)
        _push_app_log!(m, "[WARN] :layout load $name — no such layout at $path")
        return
    end
    # Wipe and reload.
    empty!(m.workspaces.workspaces)
    m.workspaces.current_idx = 0
    try
        load_layout!(m.workspaces, path)
        _ensure_default_workspace!(m)
        _push_app_log!(m, "[INFO] :layout load $name — loaded")
    catch err
        _push_app_log!(m, "[ERROR] :layout load $name: $(sprint(showerror, err))")
        _ensure_default_workspace!(m)
    end
end)
```

- [ ] **Step 3: Run tests + manual + commit**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Manual: `:layout save my-perf` then split things up, then `:layout load my-perf` → original layout returns.

```bash
git add src/tui_app.jl
git commit -m "$(cat <<'EOF'
feat(tui): :layout save / :layout load ex commands

Save writes to ~/.config/ressac/layouts/<name>.toml.
Load empties the workspace manager and reads the file. Graceful
fallback to default workspace on read failure. Layout names
restricted to [\w-]+ via the command regex.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Acceptance verification

After all 14 tasks complete:

- [ ] `grep -n 'layout_patterns\|layout_synth\|layout_logs\|layout_scope' src/` returns empty
- [ ] `view()` body is the workspace dispatcher
- [ ] `<C-w>s` / `<C-w>v` in normal mode visibly splits the workspace
- [ ] `Ctrl-1..9` jumps workspaces; `Ctrl-Shift-F` toggles floats
- [ ] `:starter reservoir-pop5` rebuilds the workspace with primary + sides
- [ ] `:q` writes layout; relaunch restores
- [ ] `:layout save my-perf` + `:layout load my-perf` round-trips
- [ ] 1684 sub-project 9 tests stay green + 14+ new integration tests pass
- [ ] Visual parity (status bar, livedoc bar, logs tail) preserved in manual smoke test
