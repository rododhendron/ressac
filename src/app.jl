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
        mode     = :normal,
    )
    # Synth editor — nothing when the side panel is closed.
    synth_editor::Union{Nothing, TK.CodeEditor} = nothing
    synth_name::String   = ""
    focus::Symbol        = :patterns   # :patterns | :synth
    logs::Vector{String} = ["[INFO] Ressac live (Tachikoma) — :q to quit, e to eval, :synth <name> to design a sound"]
    quit::Bool           = false
    tick::Int            = 0
end

"""
    _active_editor(m) -> CodeEditor

The currently-focused editor (patterns or synth).
"""
_active_editor(m::RessacApp) = m.focus === :synth && m.synth_editor !== nothing ?
                                m.synth_editor : m.editor

TK.should_quit(m::RessacApp) = m.quit

function TK.update!(m::RessacApp, evt::TK.KeyEvent)
    # Tab in normal mode swaps focus between the patterns and synth
    # panes (intercept BEFORE the editor consumes the keystroke).
    ed = _active_editor(m)
    if evt.key === :tab && ed.mode === :normal &&
       m.synth_editor !== nothing && evt.action === TK.key_press
        m.focus = m.focus === :patterns ? :synth : :patterns
        m.editor.focused        = (m.focus === :patterns)
        m.synth_editor.focused  = (m.focus === :synth)
        return
    end
    TK.handle_key!(ed, evt)
    cmd = TK.pending_command!(ed)
    isempty(cmd) || _handle_ex_command!(m, cmd)
    # Normal-mode chars trigger custom actions (eval, test synth).
    if ed.mode === :normal && evt.action === TK.key_press
        if evt.char == 'e'
            _eval_current_line!(m)
        elseif evt.char == 'T' && m.synth_editor !== nothing
            _test_current_synth!(m)
        end
    end
end

"""
    _handle_ex_command!(m, cmd)

Parse a Tachikoma-side command (string after `:`) and run the
corresponding Ressac action. Unknown commands log a warning.
"""
function _handle_ex_command!(m::RessacApp, cmd::AbstractString)
    if cmd in ("q", "quit", "q!", "qa", "qa!")
        m.quit = true
    elseif (mt = match(r"^synth\s+(\w+)$", cmd)) !== nothing
        _open_synth_pane!(m, mt.captures[1])
    elseif cmd in ("back", "close")
        _close_synth_pane!(m)
    elseif cmd in ("w", "save-synth")
        _save_current_synth!(m)
    elseif (mt = match(r"^w\s+(\w+)$", cmd)) !== nothing
        _save_current_synth!(m; new_name = mt.captures[1])
    elseif cmd in ("test", "t")
        m.synth_editor !== nothing && _test_current_synth!(m)
    else
        _push_app_log!(m, "[WARN] unknown command: :$cmd")
    end
end

function TK.view(m::RessacApp, f::TK.Frame)
    m.tick += 1
    m.editor.tick = m.tick
    m.synth_editor !== nothing && (m.synth_editor.tick = m.tick)
    buf = f.buffer

    rows = TK.split_layout(
        TK.Layout(TK.Vertical, [TK.Fixed(1), TK.Fill(), TK.Fixed(1), TK.Fixed(8)]),
        f.area,
    )
    length(rows) < 4 && return
    status_area, body_area, footer_area, logs_area = rows[1], rows[2], rows[3], rows[4]

    # Status bar
    sched = m.scheduler
    status = "ressac | $(round(sched.cps; digits=3)) cps | ev:$(sched.events_shipped[])"
    m.synth_editor !== nothing && (status *= " | synth: $(m.synth_name).scd")
    TK.set_string!(buf, status_area.x, status_area.y,
                   rpad(status, status_area.width), TK.tstyle(:title, bold=true))

    # Editor body — split horizontally when the synth panel is open.
    if m.synth_editor === nothing
        TK.render(m.editor, body_area, buf)
    else
        cols = TK.split_layout(TK.Layout(TK.Horizontal, [TK.Fill(), TK.Fill()]), body_area)
        if length(cols) >= 2
            TK.render(m.editor,       cols[1], buf)
            TK.render(m.synth_editor, cols[2], buf)
        end
    end

    # Footer (mode + hint)
    ed = _active_editor(m)
    mode_label = uppercase(String(ed.mode))
    footer = m.synth_editor === nothing ?
        " [$mode_label]  e=eval  i=insert  Esc=normal  :synth <name>  :q=quit" :
        " [$mode_label @ $(m.focus)]  e=eval  T=test  Tab=swap  :w save  :back close  :q"
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

Eval the line at the currently-focused editor's cursor.
"""
function _eval_current_line!(m::RessacApp)
    ce = _active_editor(m)
    txt = TK.text(ce)
    lines = split(txt, '\n'; keepempty=true)
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

# ---------------------------------------------------------------------
# Synth pane management
# ---------------------------------------------------------------------

_app_synth_path(name::AbstractString) =
    joinpath(pwd(), "plugins", "user-synths", String(name) * ".scd")

"""
    _open_synth_pane!(m, name)

Open the synth side panel and load `<name>.scd` from
`plugins/user-synths/` (or the starter template if the file doesn't
exist yet). Focus moves to the synth pane.
"""
function _open_synth_pane!(m::RessacApp, name::AbstractString)
    name = String(name)
    path = _app_synth_path(name)
    src = isfile(path) ? read(path, String) : join(_STARTER_SYNTHDEF(name), "\n")
    m.synth_editor = TK.CodeEditor(;
        text  = src,
        block = TK.Block(title = "synth: $name.scd",
                         border_style = TK.tstyle(:border),
                         title_style  = TK.tstyle(:title)),
        focused = true,
        tick    = m.tick,
        mode    = :normal,
    )
    m.synth_name = name
    m.focus = :synth
    m.editor.focused = false
    _push_app_log!(m, "[INFO] opened synth '$name' — T to test, :w to save, Tab to swap, :back to close")
end

function _close_synth_pane!(m::RessacApp)
    m.synth_editor === nothing && return
    name = m.synth_name
    m.synth_editor = nothing
    m.synth_name = ""
    m.focus = :patterns
    m.editor.focused = true
    _push_app_log!(m, "[INFO] closed synth '$name'")
end

"""
    _save_current_synth!(m; new_name=nothing)

Persist the synth source to `plugins/user-synths/<name>.scd`. If
`new_name` is given, save under that name AND switch the editor to
the new identity (rewriting the `SynthDef(\\old, ...)` declaration).
"""
function _save_current_synth!(m::RessacApp; new_name::Union{Nothing,AbstractString}=nothing)
    m.synth_editor === nothing && (_push_app_log!(m, "[ERROR] :w — no synth open"); return)
    old_name = m.synth_name
    name = new_name === nothing ? old_name : String(new_name)
    text = TK.text(m.synth_editor)
    if new_name !== nothing
        # Rewrite SynthDef(\old, → SynthDef(\new, in source.
        text = replace(text, "SynthDef(\\$(old_name)" => "SynthDef(\\$(name)")
        TK.set_text!(m.synth_editor, text)
        m.synth_name = name
    end
    dir = joinpath(pwd(), "plugins", "user-synths")
    isdir(dir) || mkpath(dir)
    write(_app_synth_path(name), text)
    _push_app_log!(m, "[INFO] saved synth → $(_app_synth_path(name))")
end

"""
    _test_current_synth!(m)

Reload the synth source on the SC side and fire a preview note via
`/ressac/reloadAndPlay`. Server-side `s.sync` ensures the new
SynthDef is registered before the play fires.
"""
function _test_current_synth!(m::RessacApp)
    m.synth_editor === nothing && return
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    src = TK.text(m.synth_editor)
    send_osc(sched.osc,
             encode(OSCMessage("/ressac/reloadAndPlay",
                                Any[m.synth_name, src])))
    _push_app_log!(m, "[INFO] T — test $(m.synth_name)")
end

