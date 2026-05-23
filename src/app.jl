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
    SynthTab

One open synth in the side panel. Holds the editable file name and a
CodeEditor with its own buffer + cursor. The side panel is open when
`RessacApp.synth_tabs` is non-empty.
"""
mutable struct SynthTab
    name::String
    editor::TK.CodeEditor
end

"""
    RessacApp

Top-level Tachikoma model. Holds the live scheduler, a patterns
CodeEditor, an optional stack of synth tabs (side panel when
non-empty), and the focus toggle for keystroke routing.
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
    synth_tabs::Vector{SynthTab} = SynthTab[]
    synth_tab_idx::Int           = 0      # 1-based; 0 when no tabs open
    focus::Symbol                = :patterns
    logs::Vector{String}         = ["[INFO] Ressac live (Tachikoma) — :q to quit, e to eval, :synth <name> to design a sound"]
    quit::Bool                   = false
    tick::Int                    = 0
end

"""
    _active_editor(m) -> CodeEditor

The currently-focused editor (patterns OR active synth tab).
"""
function _active_editor(m::RessacApp)
    if m.focus === :synth && !isempty(m.synth_tabs)
        return m.synth_tabs[m.synth_tab_idx].editor
    end
    return m.editor
end

_synth_pane_open(m::RessacApp) = !isempty(m.synth_tabs)
_current_synth_tab(m::RessacApp) = m.synth_tabs[m.synth_tab_idx]

TK.should_quit(m::RessacApp) = m.quit

function TK.update!(m::RessacApp, evt::TK.KeyEvent)
    ed = _active_editor(m)
    # Tab in :normal swaps focus between patterns and the active synth
    # tab. Only meaningful when at least one synth tab is open.
    if evt.key === :tab && ed.mode === :normal &&
       _synth_pane_open(m) && evt.action === TK.key_press
        _swap_focus!(m)
        return
    end
    # gt / gT cycle synth tabs while focused on the synth pane (vim
    # convention). Handled directly because the editor consumes 'g'
    # otherwise — we peek at the next char via Tachikoma's pending_key.
    if ed.mode === :normal && evt.action === TK.key_press &&
       m.focus === :synth && length(m.synth_tabs) > 1
        if evt.char == 't' && ed.pending_key == 'g'
            ed.pending_key = nothing
            _cycle_synth_tab!(m; dir=+1)
            return
        elseif evt.char == 'T' && ed.pending_key == 'g'
            ed.pending_key = nothing
            _cycle_synth_tab!(m; dir=-1)
            return
        end
    end
    TK.handle_key!(ed, evt)
    cmd = TK.pending_command!(ed)
    isempty(cmd) || _handle_ex_command!(m, cmd)
    if ed.mode === :normal && evt.action === TK.key_press
        if evt.char == 'e'
            _eval_current_line!(m)
        elseif evt.char == 'T' && _synth_pane_open(m)
            _test_current_synth!(m)
        end
    end
end

function _swap_focus!(m::RessacApp)
    m.focus = m.focus === :patterns ? :synth : :patterns
    m.editor.focused = (m.focus === :patterns)
    if _synth_pane_open(m)
        for (i, tab) in enumerate(m.synth_tabs)
            tab.editor.focused = (m.focus === :synth && i == m.synth_tab_idx)
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
        _open_synth_tab!(m, mt.captures[1])
    elseif cmd == "back"
        _close_synth_pane!(m)
    elseif cmd == "close"
        _close_active_synth_tab!(m)
    elseif cmd == "tabs"
        _list_synth_tabs!(m)
    elseif cmd in ("tabnext", "tabn")
        _cycle_synth_tab!(m; dir=+1)
    elseif cmd in ("tabprev", "tabp")
        _cycle_synth_tab!(m; dir=-1)
    elseif cmd in ("w", "save-synth")
        _save_current_synth!(m)
    elseif (mt = match(r"^w\s+(\w+)$", cmd)) !== nothing
        _save_current_synth!(m; new_name = mt.captures[1])
    elseif cmd in ("test", "t")
        _synth_pane_open(m) && _test_current_synth!(m)
    else
        _push_app_log!(m, "[WARN] unknown command: :$cmd")
    end
end

function TK.view(m::RessacApp, f::TK.Frame)
    m.tick += 1
    m.editor.tick = m.tick
    for tab in m.synth_tabs
        tab.editor.tick = m.tick
    end
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
    if _synth_pane_open(m)
        status *= " | synth: $(_current_synth_tab(m).name).scd"
        if length(m.synth_tabs) > 1
            status *= " [tab $(m.synth_tab_idx)/$(length(m.synth_tabs))]"
        end
    end
    TK.set_string!(buf, status_area.x, status_area.y,
                   rpad(status, status_area.width), TK.tstyle(:title, bold=true))

    # Editor body — split horizontally when at least one synth tab open.
    if !_synth_pane_open(m)
        TK.render(m.editor, body_area, buf)
    else
        cols = TK.split_layout(TK.Layout(TK.Horizontal, [TK.Fill(), TK.Fill()]), body_area)
        if length(cols) >= 2
            TK.render(m.editor, cols[1], buf)
            # Right pane: optional TabBar on top (when >1 tabs) + editor below.
            if length(m.synth_tabs) > 1
                synth_rows = TK.split_layout(
                    TK.Layout(TK.Vertical, [TK.Fixed(1), TK.Fill()]), cols[2])
                if length(synth_rows) >= 2
                    bar = TK.TabBar([tab.name for tab in m.synth_tabs];
                                    active  = m.synth_tab_idx,
                                    focused = (m.focus === :synth))
                    TK.render(bar, synth_rows[1], buf)
                    TK.render(_current_synth_tab(m).editor, synth_rows[2], buf)
                end
            else
                TK.render(_current_synth_tab(m).editor, cols[2], buf)
            end
        end
    end

    # Footer (mode + hint)
    ed = _active_editor(m)
    mode_label = uppercase(String(ed.mode))
    footer = if !_synth_pane_open(m)
        " [$mode_label]  e=eval  i=insert  Esc=normal  :synth <name>  :q=quit"
    elseif length(m.synth_tabs) > 1
        " [$mode_label @ $(m.focus)]  e=eval  T=test  Tab=swap  gt/gT=cycle tab  :w save  :close drop  :back exit"
    else
        " [$mode_label @ $(m.focus)]  e=eval  T=test  Tab=swap  :w save  :back close  :q"
    end
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
    _open_synth_tab!(m, name)

If `name` is already an open tab, switch to it. Otherwise create a
new tab (loading the source from disk or a starter template) and
push it onto the stack.
"""
function _open_synth_tab!(m::RessacApp, name::AbstractString)
    name = String(name)
    existing = findfirst(t -> t.name == name, m.synth_tabs)
    if existing !== nothing
        m.synth_tab_idx = existing
        m.focus = :synth
        _swap_focus!(m); m.focus = :synth   # ensure the right editor has focused=true
        _push_app_log!(m, "[INFO] switched to tab '$name'")
        return
    end
    path = _app_synth_path(name)
    src = isfile(path) ? read(path, String) : join(_STARTER_SYNTHDEF(name), "\n")
    editor = TK.CodeEditor(;
        text  = src,
        block = TK.Block(title = "synth: $name.scd",
                         border_style = TK.tstyle(:border),
                         title_style  = TK.tstyle(:title)),
        focused = true,
        tick    = m.tick,
        mode    = :normal,
    )
    push!(m.synth_tabs, SynthTab(name, editor))
    m.synth_tab_idx = length(m.synth_tabs)
    m.focus = :synth
    m.editor.focused = false
    _swap_focus!(m); m.focus = :synth
    _push_app_log!(m, "[INFO] opened synth '$name' — T test, :w save, Tab swap, gt cycle, :close drop")
end

"""
    _close_synth_pane!(m)

Close every tab and return focus to the patterns editor. Triggered
by `:back`. To drop just the active tab, see `_close_active_synth_tab!`.
"""
function _close_synth_pane!(m::RessacApp)
    isempty(m.synth_tabs) && return
    empty!(m.synth_tabs)
    m.synth_tab_idx = 0
    m.focus = :patterns
    m.editor.focused = true
    _push_app_log!(m, "[INFO] closed synth pane")
end

"""
    _close_active_synth_tab!(m)

Drop the active tab. If it was the last one, falls through to
`_close_synth_pane!` (which restores focus to patterns).
"""
function _close_active_synth_tab!(m::RessacApp)
    isempty(m.synth_tabs) && return
    name = _current_synth_tab(m).name
    deleteat!(m.synth_tabs, m.synth_tab_idx)
    if isempty(m.synth_tabs)
        m.synth_tab_idx = 0
        m.focus = :patterns
        m.editor.focused = true
        _push_app_log!(m, "[INFO] closed last synth tab '$name'")
    else
        m.synth_tab_idx = clamp(m.synth_tab_idx - 1, 1, length(m.synth_tabs))
        _swap_focus!(m); m.focus = :synth
        _push_app_log!(m, "[INFO] closed '$name' — now on '$(_current_synth_tab(m).name)'")
    end
end

function _cycle_synth_tab!(m::RessacApp; dir::Int = +1)
    length(m.synth_tabs) <= 1 && return
    n = length(m.synth_tabs)
    m.synth_tab_idx = mod(m.synth_tab_idx + dir - 1, n) + 1
    _swap_focus!(m); m.focus = :synth
end

function _list_synth_tabs!(m::RessacApp)
    if isempty(m.synth_tabs)
        _push_app_log!(m, "[INFO] no synth tabs open")
        return
    end
    for (i, tab) in enumerate(m.synth_tabs)
        marker = i == m.synth_tab_idx ? "▶" : " "
        _push_app_log!(m, "  $marker $i. $(tab.name)")
    end
end

"""
    _save_current_synth!(m; new_name=nothing)

Persist the synth source to `plugins/user-synths/<name>.scd`. If
`new_name` is given, save under that name AND switch the editor to
the new identity (rewriting the `SynthDef(\\old, ...)` declaration).
"""
function _save_current_synth!(m::RessacApp; new_name::Union{Nothing,AbstractString}=nothing)
    _synth_pane_open(m) || (_push_app_log!(m, "[ERROR] :w — no synth open"); return)
    tab = _current_synth_tab(m)
    old_name = tab.name
    name = new_name === nothing ? old_name : String(new_name)
    text = TK.text(tab.editor)
    if new_name !== nothing
        text = replace(text, "SynthDef(\\$(old_name)" => "SynthDef(\\$(name)")
        TK.set_text!(tab.editor, text)
        tab.name = name
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
    _synth_pane_open(m) || return
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    tab = _current_synth_tab(m)
    src = TK.text(tab.editor)
    send_osc(sched.osc,
             encode(OSCMessage("/ressac/reloadAndPlay", Any[tab.name, src])))
    _push_app_log!(m, "[INFO] T — test $(tab.name)")
end

