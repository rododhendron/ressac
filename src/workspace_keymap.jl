# src/workspace_keymap.jl
# C-w pane mode state machine. Pane mode is persistent: it stays
# active until the user explicitly exits with Esc / Enter / Ctrl-W.
# Splits, navigation, close all preserve the mode so a quick run of
# ops doesn't need a Ctrl-W between each.

mutable struct PaneModeState
    active::Bool
end
PaneModeState() = PaneModeState(false)

const _PANE_MODE = PaneModeState()

"""
    _dispatch_pane_mode_key(wm, char) -> Bool

Handle one keystroke while in pane mode. Returns `true` if the key
was a recognized op (consumed), `false` if not. Recognized keys:

  s — hsplit (new editor pane below)
  v — vsplit (new editor pane to the right)
  h/j/k/l — navigate left/down/up/right
  c — close focused pane

The caller is responsible for exit handling (Esc / Enter / Ctrl-W
turn pane mode off). Recognized ops do NOT auto-exit.
"""
function _dispatch_pane_mode_key(wm::WorkspaceManager, char::Char)
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
        return false
    end
    return true
end
