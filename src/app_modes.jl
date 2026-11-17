# src/app_modes.jl
# Le contexte de jeu — :play (les patterns), :design (un son), :explore
# (l'explorateur). Ce ne sont plus des écrans : c'est ce que porte la pane
# qui a le clavier, et c'est ce qui choisit les touches de mode
# (keymap.jl : `scope_in_mode`, `scopes_for_mode`). Les commandes, elles,
# valent partout.

const _MODE_LABELS = Dict(:play => "PATTERNS", :design => "SON", :explore => "EXPLORATEUR")

"""
    _workspace_mode(m) -> :play | :design | :explore

Le contexte courant, lu sur la pane focalisée.
"""
function _workspace_mode(m::RessacApp)
    pane = _focused_pane_impl(m)
    pane isa SynthExplorerPane && return :explore
    _focused_role(m) === :synth && return :design
    (pane isa WaveformPane || pane isa DronePane || pane isa SynthDocPane) && return :design
    return :play
end

_mode_label(mode::Symbol) = get(_MODE_LABELS, mode, "PATTERNS")
