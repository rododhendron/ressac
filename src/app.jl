# New Tachikoma-based TUI for Ressac. Lives alongside the existing
# TerminalUserInterfaces.jl-based TUI during the migration. Entry point
# is `live2()` (parallel to `live()`); once feature parity is reached
# `live()` will switch over and the old `tui_*.jl` files get removed.
#
# Architecture: Elm (Model/update!/view). The Ressac scheduler + audio
# layer is unchanged — only the editor + viz layer is being replaced.

using Tachikoma
const TK = Tachikoma

"""
    RessacApp

Top-level Tachikoma model. Wraps the live scheduler + a CodeEditor for
the pattern buffer. Other panels (synth edit, scope, modals) get added
in subsequent commits.
"""
@kwdef mutable struct RessacApp <: TK.Model
    scheduler::Scheduler
    editor::TK.CodeEditor = TK.CodeEditor(;
        text     = "@d1 p\"bd hh sn hh\"",
        block    = TK.Block(title = "patterns",
                            border_style = TK.tstyle(:border),
                            title_style  = TK.tstyle(:title)),
        focused  = true,
        tick     = 0,
    )
    logs::Vector{String} = ["[INFO] Ressac live (Tachikoma) — :q to quit, e to eval"]
    quit::Bool           = false
    tick::Int            = 0
end

TK.should_quit(m::RessacApp) = m.quit

function TK.update!(m::RessacApp, evt::TK.KeyEvent)
    TK.handle_key!(m.editor, evt)
    cmd = TK.pending_command!(m.editor)
    if cmd in ("q", "quit", "q!")
        m.quit = true
    elseif !isempty(cmd)
        _push_app_log!(m, "[INFO] command: :$cmd")
    end
    # Manual eval trigger: when the editor is in :normal mode and `e`
    # was the last keystroke, eval the line under the cursor.
    if TK.editor_mode(m.editor) === :normal && evt.char == 'e'
        _eval_current_line!(m)
    end
end

function TK.view(m::RessacApp, f::TK.Frame)
    m.tick += 1
    m.editor.tick = m.tick
    buf = f.buffer

    rows = TK.split_layout(
        TK.Layout(TK.Vertical, [TK.Fixed(1), TK.Fill(), TK.Fixed(1), TK.Fixed(8)]),
        f.area,
    )
    length(rows) < 4 && return
    status_area, body_area, footer_area, logs_area = rows[1], rows[2], rows[3], rows[4]

    # Status bar
    sched = m.scheduler
    status = "ressac (tachikoma) | $(round(sched.cps; digits=3)) cps | ev:$(sched.events_shipped[])"
    TK.set_string!(buf, status_area.x, status_area.y,
                   rpad(status, status_area.width), TK.tstyle(:title, bold=true))

    # Editor body
    TK.render(m.editor, body_area, buf)

    # Footer (mode + hint)
    mode = TK.editor_mode(m.editor)
    mode_label = uppercase(String(mode))
    footer = " [$mode_label]  e=eval  :q=quit  i=insert  Esc=normal"
    TK.set_string!(buf, footer_area.x, footer_area.y,
                   rpad(footer, footer_area.width), TK.tstyle(:accent))

    # Logs (last N)
    tail = m.logs[max(1, end - logs_area.height + 1):end]
    for (i, line) in enumerate(tail)
        i > logs_area.height && break
        TK.set_string!(buf,
                       logs_area.x,
                       logs_area.y + i - 1,
                       first(line, logs_area.width),
                       TK.tstyle(:text_dim))
    end
end

function _push_app_log!(m::RessacApp, line::AbstractString)
    push!(m.logs, String(line))
    length(m.logs) > 200 && popfirst!(m.logs)
end

"""
    _eval_current_line!(m)

Eval the buffer line at the editor cursor — same semantics as the
existing `_eval_block!`: wrap in begin/end, snapshot @dN slot, log
the result.
"""
function _eval_current_line!(m::RessacApp)
    ce = m.editor
    text = TK.get_text(ce)
    lines = split(text, '\n'; keepempty=true)
    row = ce.cursor_row
    1 <= row <= length(lines) || return
    line = lines[row]
    isempty(strip(line)) && return
    try
        ex = Meta.parse(line)
        result = Core.eval(Main, ex)
        rstr = sprint(io -> show(IOContext(io, :limit=>true, :displaysize=>(1, 60)), result))
        _push_app_log!(m, "[INFO] eval ⇒ $rstr")
    catch err
        _push_app_log!(m, "[ERROR] $(sprint(showerror, err))")
    end
end

