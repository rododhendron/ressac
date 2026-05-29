# src/workspace_keymap.jl
# C-w pane mode + resize mode state machine. Single-shot by default;
# Tab toggles sticky.
#
# This file ships the pure state machine + dispatch table. The
# integration into update! lives in tui_app.jl and is wired in
# Task 15 (alongside the view() swap) — having the keymap intercept
# C-w without visible feedback would just confuse users.

mutable struct PaneModeState
    active::Bool
    sticky::Bool
end
PaneModeState() = PaneModeState(false, false)

const _PANE_MODE = PaneModeState()

"""
    _dispatch_pane_mode_key(wm, char) -> Bool

Handle one keystroke while in pane mode. Returns `true` if the key
was a recognized op (consumed), `false` if not. Recognized keys:

  s — hsplit (new editor pane below)
  v — vsplit (new editor pane to the right)
  h/j/k/l — navigate left/down/up/right
  c — close focused pane

Single-shot mode auto-exits after a consumed key. Sticky mode
(toggled by Tab in the caller) stays active.
"""
function _dispatch_pane_mode_key(wm::WorkspaceManager, char::Char)
    handled = true
    if char == 's'
        cmd_hsplit!(wm, "editor", Dict{String,Any}())
    elseif char == 'v'
        cmd_vsplit!(wm, "editor", Dict{String,Any}())
    elseif char == 'h'
        cmd_focus!(wm, :left)
    elseif char == 'j'
        cmd_focus!(wm, :down)
    elseif char == 'k'
        cmd_focus!(wm, :up)
    elseif char == 'l'
        cmd_focus!(wm, :right)
    elseif char == 'c'
        cmd_close!(wm)
    else
        handled = false
    end
    if handled && !_PANE_MODE.sticky
        _PANE_MODE.active = false
    end
    return handled
end
