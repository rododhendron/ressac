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
            _footer_line(m),
            _separator(),
            _logs_pane(m)],
        [1, 1, 0, 1, 1, 1, 5],   # 0 for the expand slot — recomputed at render
        3,                        # editor
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
    rendered = String[]
    # Track which logical buffer row each rendered row maps to, so the
    # cursor overlay can find its line even when viz rows are interleaved.
    logical = Int[]
    for (i, line) in enumerate(m.buffer)
        prefix = ""
        if m.mode === :visual_line && m.visual_anchor !== nothing
            rs, re = _visual_range(m)
            if rs <= i <= re
                prefix = "│ "
            end
        end
        marker = _active_marker(m, i)
        push!(rendered, prefix * line * marker)
        push!(logical, i)
        # Pattern viz: render a sparse grid under any line that looks
        # like a slot definition with a mini-notation literal.
        viz = _pattern_viz_line(line)
        if viz !== nothing
            push!(rendered, "    " * viz)
            push!(logical, 0)   # 0 = synthetic line, no buffer mapping
        end
    end
    _EditorPane(m, rendered, logical)
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
    logical::Vector{Int}  # buffer row each rendered line maps to (0 = synthetic)
end

function TUI.render(p::_EditorPane, area::TUI.Rect, buf::TUI.Buffer)
    m = p.model
    m.editor_screen_left   = TUI.left(area)
    m.editor_screen_top    = TUI.top(area)
    m.editor_screen_height = TUI.height(area)
    TUI.height(area) < 1 && return
    avail = TUI.height(area)
    # Render each line with a per-line style: synthetic viz lines get a
    # dim grey so they read as annotations, not code.
    for (i, line) in enumerate(p.lines)
        i > avail && break
        clipped = first(line, TUI.width(area))
        is_viz = p.logical[i] == 0
        style = is_viz ? TUI.Crayon(; foreground=:dark_gray) : TUI.Crayon()
        TUI.set(buf, TUI.left(area), TUI.top(area) + i - 1, String(clipped), style)
    end
    # Find the rendered row that maps to m.cursor_row so we can overlay
    # the cursor in the right place (viz lines push subsequent buffer
    # rows down).
    m.mode in (:insert, :normal) || return
    cursor_render_row = findfirst(==(m.cursor_row), p.logical)
    cursor_render_row === nothing && return
    cursor_render_row <= avail || return
    line = m.buffer[m.cursor_row]
    col = clamp(m.cursor_col, 1, lastindex(line) + 1)
    ch = col > lastindex(line) ? " " : string(line[col])
    cursor_x = TUI.left(area) + col - 1
    cursor_y = TUI.top(area) + cursor_render_row - 1
    cursor_x < TUI.left(area) + TUI.width(area) || return
    TUI.set(buf, cursor_x, cursor_y, ch, TUI.Crayon(; negative=true))
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
    raw = isempty(m.logs) ? String[""] : collect(last(m.logs, 8))
    _TextLines(raw, TUI.Crayon(; foreground=:blue))
end
