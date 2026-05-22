function TUI.init!(m::LiveModel, ::TUI.TerminalBackend)
    _push_log!(m, "[INFO] Ressac live — i to edit, Esc to normal, :q to quit")
end

function TUI.update!(m::LiveModel, evt::TUI.KeyEvent)
    _dispatch_key!(m, (; code=TUI.keycode(evt),
                        modifiers=TUI.keymodifier(evt),
                        kind=evt.data.kind))
end

function TUI.view(m::LiveModel)
    status = _activity_widget(m)
    editor = _editor_pane(m)
    hint   = _mode_hint_line(m)
    cmd    = _command_line(m)
    compl  = _completion_hint_line(m)
    logs   = _logs_pane(m)
    TUI.Layout(;
        widgets     = [status, editor, hint, cmd, compl, logs],
        constraints = [TUI.Min(1), TUI.Percent(70), TUI.Min(1),
                       TUI.Min(1), TUI.Min(1), TUI.Min(8)],
        orientation = :vertical,
    )
end

function _mode_hint_line(m::LiveModel)
    text = "[" * uppercase(String(m.mode)) * "] " * _mode_hint(m.mode)
    _TextLines([text], TUI.Crayon(; foreground=:cyan))
end

function _completion_hint_line(m::LiveModel)
    if isempty(m.completions)
        return _TextLines([""], TUI.Crayon())
    end
    parts = String[]
    for (i, cand) in enumerate(m.completions)
        if i == m.completion_cycle_idx
            push!(parts, "[" * cand * "]")
        else
            push!(parts, cand)
        end
    end
    text = join(parts, "  ")
    _TextLines([text], TUI.Crayon(; foreground=:magenta))
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
    for (i, line) in enumerate(m.buffer)
        prefix = ""
        if m.mode === :visual_line && m.visual_anchor !== nothing
            rs, re = _visual_range(m)
            if rs <= i <= re
                prefix = "│ "
            end
        end
        marker = _active_marker(m, i)
        display_line = if i == m.cursor_row && m.mode in (:insert, :normal)
            _line_with_cursor(line, m.cursor_col)
        else
            line
        end
        push!(rendered, prefix * display_line * marker)
    end
    _BufferPane(rendered, TUI.Crayon())
end

# Splice a `▌` cursor glyph into `line` at byte index `col`, defensively:
# if `col` lands inside a multi-byte UTF-8 character (shouldn't happen
# given buffer-helper invariants, but cheap to guard) we snap to the
# enclosing codepoint start instead of throwing.
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
