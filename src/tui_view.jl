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
    cmd    = _command_line(m)
    logs   = _logs_pane(m)
    TUI.Layout(;
        widgets = [status, editor, cmd, logs],
        constraints = [TUI.Min(3), TUI.Percent(60), TUI.Min(3), TUI.Min(8)],
        orientation = :vertical,
    )
end

function _activity_widget(m::LiveModel)
    sched = m.scheduler
    parts = String[]
    push!(parts, "$(round(sched.cps; digits=3))cps")
    push!(parts, _cycle_indicator(sched))
    push!(parts, "│")
    for (slot, _) in sched.patterns
        push!(parts, "$(String(slot))" * _slot_grid(sched, slot))
    end
    for (slot, (_, at)) in sched.pending
        push!(parts, "$(String(slot)) ⏱→cyc$(Int(at))")
    end
    push!(parts, "│ $(uppercase(String(m.mode)))")
    text = join(parts, "  ")
    return _zone_v2("ressac", text, TUI.Crayon(; bold=true))
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
            col = m.cursor_col
            if col > lastindex(line)
                line * "▌"
            else
                line[1:prevind(line, col)] * "▌" * line[col:end]
            end
        else
            line
        end
        push!(rendered, prefix * display_line * marker)
    end
    _BufferPane(rendered, TUI.Crayon())
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
    return _zone_v2("cmd", text, TUI.Crayon(; foreground=:green))
end

function _logs_pane(m::LiveModel)
    text = isempty(m.logs) ? "(no logs)" : join(last(m.logs, 8), "\n")
    return _zone_v2("logs", text, TUI.Crayon(; foreground=:blue))
end

function _zone_v2(title::AbstractString, text::AbstractString, style)
    words = TUI.make_words(text, style)
    isempty(words) && push!(words, TUI.Word(" ", style))
    TUI.Paragraph(TUI.Block(; title=String(title)), words, 1, Ref{Int}(0))
end
