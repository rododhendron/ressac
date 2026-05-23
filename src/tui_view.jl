function TUI.init!(m::LiveModel, ::TUI.TerminalBackend)
    _push_log!(m, "[INFO] Ressac live — i to edit, Esc to normal, :q to quit")
end

function TUI.update!(m::LiveModel, evt::TUI.KeyEvent)
    _dispatch_key!(m, (; code=TUI.keycode(evt),
                        modifiers=TUI.keymodifier(evt),
                        kind=evt.data.kind))
end

function TUI.update!(m::LiveModel, evt::TUI.MouseEvent)
    _handle_mouse!(m, evt.data)
end

function TUI.view(m::LiveModel)
    return _AppView(m)
end

"""
    _FastVStack(widgets, fixed_heights, expand_index)

A drop-in replacement for `TUI.Layout(orientation=:vertical)` that
skips the Kiwi constraint solver and computes its rectangles directly.
Profile (60 FPS render, 80×24 terminal): `TUI.Layout` ≈ 12 ms/frame
because the solver runs every frame; this stack is ~0.05 ms.

`fixed_heights[i]` is the row count for widget `i`; the widget at
`expand_index` takes whatever's left after the fixed widgets are
allocated (clamped ≥ 1).
"""
struct _FastVStack
    widgets::Vector{Any}
    fixed_heights::Vector{Int}
    expand_index::Int
end

function TUI.render(stack::_FastVStack, area::TUI.Rect, buf::TUI.Buffer)
    total_fixed = sum(stack.fixed_heights) -
                  stack.fixed_heights[stack.expand_index]
    expand_h = max(1, TUI.height(area) - total_fixed)
    y = TUI.top(area)
    x = TUI.left(area)
    w = TUI.width(area)
    for (i, widget) in enumerate(stack.widgets)
        h = i == stack.expand_index ? expand_h : stack.fixed_heights[i]
        sub = TUI.Rect(x, y, w, h)
        TUI.render(widget, sub, buf)
        y += h
    end
end

function _build_main_layout(m::LiveModel)
    # Layout: status / editor / footer / logs, separated by thin rules so
    # the panes read as discrete zones instead of free-floating text.
    # Heights: 1 (status) + 1 (sep) + EXPAND (editor) + 1 (sep) +
    #          1 (footer) + 1 (sep) + 5 (logs).
    _FastVStack(
        Any[_activity_widget(m),
            _separator(),
            _editor_pane(m),
            _separator(),
            _livedoc_line(m),
            _separator(),
            _footer_line(m),
            _separator(),
            _logs_pane(m)],
        [1, 1, 0, 1, 1, 1, 1, 1, 5],
        3,
    )
end

"""
    _separator()

A 1-row widget that fills its area with `─`. Used as a visual divider
between the major panes. Width is whatever the layout assigns it.
"""
struct _Separator end
_separator() = _Separator()

function TUI.render(::_Separator, area::TUI.Rect, buf::TUI.Buffer)
    TUI.height(area) < 1 && return
    line = "─"^TUI.width(area)
    TUI.set(buf, TUI.left(area), TUI.top(area), line,
            TUI.Crayon(; foreground=:dark_gray))
end

"""
    _footer_line(m)

A 1-row composite that shows whatever's most relevant for the moment:

- `:command` mode → the command being typed (`:foo█`), with completions
  appended inline if any (` › samples  [synths]`).
- non-command modes → the mode hint string (`[NORMAL] i|V|:|K|e ...`).

Folding these into one row keeps the total layout the same height as
before SP6 (status + editor + 1 footer + logs), so a 24-line terminal
doesn't lose any editor rows to the new visual UX.
"""
function _footer_line(m::LiveModel)
    if !isempty(m.synth_editing) && m.mode !== :command
        if m.focus === :synth
            text = "[SYNTH→ $(m.synth_editing).scd] T/:test play | :reload | :save-synth | Tab to swap | :back"
        else
            text = "[←PATTERNS  synth=$(m.synth_editing)] Tab / :swap → synth | T test current synth | :back"
        end
        return _TextLines([text], TUI.Crayon(; foreground=:yellow))
    end
    if m.mode === :command
        text = "$(m.command_prefix)$(m.command_buffer)█"
        if !isempty(m.completions)
            parts = String[]
            for (i, cand) in enumerate(m.completions)
                push!(parts, i == m.completion_cycle_idx ? "[" * cand * "]" : cand)
            end
            text *= "   › " * join(parts, "  ")
        end
        return _TextLines([text], TUI.Crayon(; foreground=:green))
    end
    if !isempty(m.completions)
        parts = String[]
        for (i, cand) in enumerate(m.completions)
            push!(parts, i == m.completion_cycle_idx ? "[" * cand * "]" : cand)
        end
        return _TextLines(["completions:  " * join(parts, "  ")],
                          TUI.Crayon(; foreground=:magenta))
    end
    text = "[" * uppercase(String(m.mode)) * "] " * _mode_hint(m.mode)
    _TextLines([text], TUI.Crayon(; foreground=:cyan))
end

function _mode_hint_line(m::LiveModel)
    # Retained for back-compat with callers; the unified footer is preferred.
    text = "[" * uppercase(String(m.mode)) * "] " * _mode_hint(m.mode)
    _TextLines([text], TUI.Crayon(; foreground=:cyan))
end

function _activity_widget(m::LiveModel)
    sched = m.scheduler
    parts = String[]
    push!(parts, "ressac")
    push!(parts, "$(round(sched.cps; digits=3))cps")
    push!(parts, _cycle_indicator(sched))
    push!(parts, "│")
    for (slot, _) in sched.patterns
        push!(parts, "$(String(slot))" * _slot_grid(sched, slot))
    end
    for (slot, (_, at)) in sched.pending
        push!(parts, "$(String(slot)) ⏱→cyc$(Int(at))")
    end
    push!(parts, "nT:$(Threads.nthreads()) ev:$(m.scheduler.events_shipped[])")
    push!(parts, "│ $(uppercase(String(m.mode)))")
    text = join(parts, "  ")
    _TextLines([text], TUI.Crayon(; bold=true))
end

function _cycle_indicator(s::Scheduler)
    s.t_start == 0.0 && return "▹▹▹▹"
    cur = (time() - s.t_start) * s.cps
    pos = floor(Int, (cur - floor(cur)) * 4) + 1
    glyphs = ['▹', '▹', '▹', '▹']
    1 <= pos <= 4 && (glyphs[pos] = '▸')
    return String(glyphs)
end

function _slot_grid(s::Scheduler, slot::Symbol)
    haskey(s.last_fired_at, slot) || return "◦◦◦◦"
    fresh = (time() - s.last_fired_at[slot]) < 0.2
    fresh || return "◦◦◦◦"
    p = s.patterns[slot]
    cur = floor((time() - s.t_start) * s.cps)
    events = p(Rational{Int64}(Int(cur)), Rational{Int64}(Int(cur) + 1))
    cells = ['◦', '◦', '◦', '◦']
    for ev in events
        offset = Float64(ev.start) - cur
        idx = clamp(floor(Int, offset * 4) + 1, 1, 4)
        cells[idx] = '•'
    end
    return String(cells)
end

"""
    _BufferPane(lines, style)

A custom TUI widget that writes pre-rendered text lines directly into the
target buffer area. Sidesteps `TUI.Paragraph`'s whitespace re-joining and
`TUI.Block.inner`'s ≥2-row requirement, which together make Paragraph
unsuitable for single-row multi-line displays.
"""
struct _BufferPane
    lines::Vector{String}
    style::TUI.Crayon
end

function TUI.render(p::_BufferPane, area::TUI.Rect, buf::TUI.Buffer)
    TUI.height(area) < 1 && return
    avail = TUI.height(area)
    for (i, line) in enumerate(p.lines)
        i > avail && break
        # Clip the line to the area width to avoid overflow.
        clipped = first(line, TUI.width(area))
        TUI.set(buf, TUI.left(area), TUI.top(area) + i - 1, String(clipped), p.style)
    end
end

"""
    _TextLines(lines, style)

Generic multi-line widget for stacking pre-rendered text rows. Same idea
as `_BufferPane` but for read-only panes (status, command prompt, logs).
Bypasses `TUI.Block`'s frame-overlap quirk by writing directly to the
buffer.
"""
struct _TextLines
    lines::Vector{String}
    style::TUI.Crayon
end

function TUI.render(p::_TextLines, area::TUI.Rect, buf::TUI.Buffer)
    TUI.height(area) < 1 && return
    avail = TUI.height(area)
    for (i, line) in enumerate(p.lines)
        i > avail && break
        clipped = first(line, TUI.width(area))
        TUI.set(buf, TUI.left(area), TUI.top(area) + i - 1, String(clipped), p.style)
    end
end

function _editor_pane(m::LiveModel)
    # When a synth is being edited, split the editor area horizontally:
    # patterns on the left, synth source on the right. Always-on; the
    # focused side has its cursor highlighted.
    if !isempty(m.synth_editing)
        return _SplitEditor(m)
    end
    return _build_pane_for_main(m)
end

"""
    _build_pane_for_main(m)

Render the main pattern buffer with pattern-viz lines interleaved.
Used both as the single-pane editor and as the left side of the split.
"""
function _build_pane_for_main(m::LiveModel)
    lines, row, col = _focus_safe_main_view(m)
    rendered = String[]
    logical  = Int[]
    visual_active = (m.focus === :main) && m.mode === :visual_line && m.visual_anchor !== nothing
    for (i, line) in enumerate(lines)
        prefix = ""
        if visual_active
            rs, re = _visual_range(m)
            if rs <= i <= re
                prefix = "│ "
            end
        end
        marker = _active_marker(m, i)
        push!(rendered, prefix * line * marker)
        push!(logical, i)
        viz = _pattern_viz_line(line)
        if viz !== nothing
            push!(rendered, "    " * viz)
            push!(logical, 0)
        end
    end
    is_focused = m.focus === :main
    _EditorPane(m, rendered, logical, row, col, is_focused)
end

"""
    _build_pane_for_synth(m)

Render the synth source (no pattern viz — this is SCD code, not
mini-notation). Used as the right side of the split.
"""
function _build_pane_for_synth(m::LiveModel)
    lines, row, col = _synth_buffer_view(m)
    rendered = String[]
    logical  = Int[]
    for (i, line) in enumerate(lines)
        push!(rendered, line)
        push!(logical, i)
    end
    is_focused = m.focus === :synth
    _EditorPane(m, rendered, logical, row, col, is_focused)
end

"""
    _focus_safe_main_view(m) -> (lines, row, col)

Return the main buffer's view regardless of which side has focus.
"""
function _focus_safe_main_view(m::LiveModel)
    if m.focus === :main
        return (m.buffer, m.cursor_row, m.cursor_col)
    end
    return (m.synth_stash_buffer, m.synth_stash_row, m.synth_stash_col)
end

"""
    _SplitEditor(model)

Horizontal split of the editor area into a main pane (left) and a
synth-edit pane (right). The split is 50/50 with a 1-column gutter.
Each side renders its own cursor; the unfocused one is grey.
"""
struct _SplitEditor
    model::LiveModel
end

function TUI.render(s::_SplitEditor, area::TUI.Rect, buf::TUI.Buffer)
    m = s.model
    w = TUI.width(area)
    h = TUI.height(area)
    h < 3 && return  # need a row for titles + at least one for content
    # Reserve a thin gutter column between the two panes.
    half = max(1, (w - 1) ÷ 2)
    left_w  = half
    right_w = w - half - 1
    gutter_x = TUI.left(area) + half
    # Title row for each pane — makes the split unambiguous: bold yellow
    # on the focused side, dim grey on the other.
    title_y = TUI.top(area)
    left_title  = " patterns"
    right_title = " synth: " * m.synth_editing * ".scd"
    left_style  = m.focus === :main ?
                  TUI.Crayon(; foreground=:yellow, bold=true) :
                  TUI.Crayon(; foreground=:dark_gray)
    right_style = m.focus === :synth ?
                  TUI.Crayon(; foreground=:yellow, bold=true) :
                  TUI.Crayon(; foreground=:dark_gray)
    TUI.set(buf, TUI.left(area),  title_y, rpad(first(left_title,  left_w),  left_w),  left_style)
    TUI.set(buf, gutter_x + 1,    title_y, rpad(first(right_title, right_w), right_w), right_style)
    # Underline under each title — visually separates header from content.
    TUI.set(buf, TUI.left(area), title_y + 1, "─"^left_w,  TUI.Crayon(; foreground=:dark_gray))
    TUI.set(buf, gutter_x + 1,   title_y + 1, "─"^right_w, TUI.Crayon(; foreground=:dark_gray))
    # Gutter glyphs (full height including title rows).
    for y in 0:(h - 1)
        TUI.set(buf, gutter_x, TUI.top(area) + y, "│",
                TUI.Crayon(; foreground=:dark_gray))
    end
    # Content areas live below the title + underline (2 rows reserved).
    content_top = title_y + 2
    content_h   = h - 2
    left_content  = TUI.Rect(TUI.left(area), content_top, left_w,  content_h)
    right_content = TUI.Rect(gutter_x + 1,   content_top, right_w, content_h)
    TUI.render(_build_pane_for_main(m),  left_content,  buf)
    TUI.render(_build_pane_for_synth(m), right_content, buf)
end

"""
    _EditorPane(model, lines)

Renders `lines` like `_BufferPane`, and as a side effect captures the
screen-space rectangle assigned by the Layout into the model so mouse
events can translate terminal (col, row) coordinates back into buffer
(col, row) positions.
"""
struct _EditorPane
    model::LiveModel
    lines::Vector{String}
    logical::Vector{Int}
    pane_cursor_row::Int    # cursor in THIS pane's buffer (may differ from m.cursor_*)
    pane_cursor_col::Int
    is_focused::Bool
end

# Backwards-compatible 3-arg constructor used in legacy code paths.
_EditorPane(m::LiveModel, lines::Vector{String}, logical::Vector{Int}) =
    _EditorPane(m, lines, logical, m.cursor_row, m.cursor_col, true)

function TUI.render(p::_EditorPane, area::TUI.Rect, buf::TUI.Buffer)
    m = p.model
    # Only the focused pane drives the mouse-wheel screen-space mapping.
    if p.is_focused
        m.editor_screen_left   = TUI.left(area)
        m.editor_screen_top    = TUI.top(area)
        m.editor_screen_height = TUI.height(area)
    end
    TUI.height(area) < 1 && return
    avail = TUI.height(area)
    base_style = p.is_focused ? TUI.Crayon() : TUI.Crayon(; foreground=:dark_gray)
    for (i, line) in enumerate(p.lines)
        i > avail && break
        clipped = first(line, TUI.width(area))
        is_viz = p.logical[i] == 0
        style = is_viz ? TUI.Crayon(; foreground=:dark_gray) : base_style
        TUI.set(buf, TUI.left(area), TUI.top(area) + i - 1, String(clipped), style)
    end
    # Cursor overlay — focused pane gets inverted (block) cursor, unfocused
    # gets nothing (its position is preserved in state but invisible).
    p.is_focused || return
    m.mode in (:insert, :normal) || return
    cursor_render_row = findfirst(==(p.pane_cursor_row), p.logical)
    cursor_render_row === nothing && return
    cursor_render_row <= avail || return
    line = p.lines[cursor_render_row]
    # The on-screen line includes a possible "│ " visual prefix and a marker
    # suffix — but the cursor col is a byte index into the *raw* buffer line.
    # Recompute via the raw buffer, not the rendered one.
    1 <= p.pane_cursor_row <= length_raw_buffer(m, p.is_focused) || return
    raw_line = raw_buffer_line(m, p.pane_cursor_row, p.is_focused)
    col = clamp(p.pane_cursor_col, 1, lastindex(raw_line) + 1)
    ch  = col > lastindex(raw_line) ? " " : string(raw_line[col])
    cursor_x = TUI.left(area) + col - 1
    cursor_y = TUI.top(area) + cursor_render_row - 1
    cursor_x < TUI.left(area) + TUI.width(area) || return
    TUI.set(buf, cursor_x, cursor_y, ch, TUI.Crayon(; negative=true))
end

# Pick the right backing buffer for cursor-position computation.
function length_raw_buffer(m::LiveModel, focused::Bool)
    if isempty(m.synth_editing)
        return length(m.buffer)
    end
    lines = focused ?
            (m.focus === :main ? m.buffer : m.buffer) :
            (m.focus === :main ? m.synth_stash_buffer : m.synth_stash_buffer)
    return length(lines)
end
function raw_buffer_line(m::LiveModel, row::Int, focused::Bool)
    # Focused pane always reads from m.buffer; unfocused from synth_stash_*.
    if !isempty(m.synth_editing) && !focused
        return m.synth_stash_buffer[row]
    end
    return m.buffer[row]
end

"""
    _pattern_viz_line(line) -> Union{Nothing, String}

If `line` looks like `@dN <something> p"..." …`, parse the
mini-notation and return a one-line visual representation of the
hits on a 16-step grid. Returns `nothing` otherwise.

Format: 16 cells, `•` for a hit, `·` for silence. Hits are aligned to
the start time of each event within cycle 0.
"""
function _pattern_viz_line(line::AbstractString)
    # Skip commented lines and lines that aren't slot definitions.
    startswith(strip(line), "#") && return nothing
    occursin(r"^\s*@d\d+\b", line) || return nothing
    # Extract the first p"..." literal.
    mt = match(r"p\"([^\"]*)\"", line)
    mt === nothing && return nothing
    pat_str = mt.captures[1]
    isempty(strip(pat_str)) && return nothing
    parsed = try
        parse_minino(String(pat_str))
    catch
        return nothing
    end
    events = try
        parsed(0 // 1, 1 // 1)
    catch
        return nothing
    end
    cells = fill('·', 16)
    for ev in events
        # ev.start ∈ [0, 1); map to a 0-based cell index.
        idx = clamp(floor(Int, Float64(ev.start) * 16) + 1, 1, 16)
        cells[idx] = '•'
    end
    # Insert thin separators every 4 cells for readability.
    out = IOBuffer()
    for (i, c) in enumerate(cells)
        write(out, c)
        write(out, ' ')
        i % 4 == 0 && i != 16 && write(out, '│', ' ')
    end
    return String(take!(out))
end

# Kept around for back-compat with any caller still using it (none in-tree).
# The new editor pane paints an inverted-color cell directly into the buffer
# at the cursor position, so this string-splicing helper is no longer used
# on the hot path.
function _line_with_cursor(line::AbstractString, col::Integer)
    n = lastindex(line)
    if col > n
        return line * "▌"
    end
    safe_col = isvalid(line, col) ? col : thisind(line, col)
    safe_col < 1 && return "▌" * line
    return line[1:prevind(line, safe_col)] * "▌" * line[safe_col:end]
end

function _active_marker(m::LiveModel, row::Int)
    for (slot, (rs, re)) in m.last_eval_block
        rs <= row <= re || continue
        haskey(m.scheduler.patterns, slot) || continue
        return "  ▶"
    end
    return ""
end

function _command_line(m::LiveModel)
    text = m.mode === :command ? "$(m.command_prefix)$(m.command_buffer)█" : " "
    _TextLines([text], TUI.Crayon(; foreground=:green))
end

function _logs_pane(m::LiveModel)
    _LogsPane(m)
end

"""
    _LogsPane(model)

Renders the tail of `m.logs` — always the **last** `height(area)`
entries so newly-pushed lines are immediately visible. The previous
`_TextLines(last(logs, 8))` rendered from the top of the widget, so
when the pane shrunk to 5-6 rows the newest 2-3 lines were clipped.
"""
struct _LogsPane
    model::LiveModel
end

function TUI.render(p::_LogsPane, area::TUI.Rect, buf::TUI.Buffer)
    h = TUI.height(area)
    h < 1 && return
    logs = p.model.logs
    n = length(logs)
    if n == 0
        TUI.set(buf, TUI.left(area), TUI.top(area), "",
                TUI.Crayon(; foreground=:blue))
        return
    end
    start = max(1, n - h + 1)
    tail = view(logs, start:n)
    style = TUI.Crayon(; foreground=:blue)
    for (i, line) in enumerate(tail)
        clipped = first(line, TUI.width(area))
        TUI.set(buf, TUI.left(area), TUI.top(area) + i - 1, String(clipped), style)
    end
end
