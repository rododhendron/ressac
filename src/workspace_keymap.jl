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

# Les touches du mode pane (s, v, h/j/k/l, c, z, < > - + = r, et les sorties)
# sont au registre : scope `:pane_mode`, préfixe « Ctrl-w » — app_keymap.jl.
