# src/app_modes.jl
# Les trois modes de Ressac — PLAY (les patterns), DESIGN (un son),
# EXPLORE (l'explorateur génétique) — sont des workspaces, et chacun a
# son vocabulaire : l'aide complète, la palette et la complétion ne
# montrent que ce qui a un sens là où on est. Une commande propre à un
# autre mode y emmène d'abord (`:synth` depuis PLAY ouvre DESIGN).

const _MODE_OF_WORKSPACE = Dict("PLAY" => :play, "DESIGN" => :design, "EXPLORE" => :explore)
const _WORKSPACE_OF_MODE = Dict(:play => "PLAY", :design => "DESIGN", :explore => "EXPLORE")

"""
    _workspace_mode(m) -> :play | :design | :explore

Le mode courant : le nom du workspace, sinon ce que porte la pane focalisée.
"""
function _workspace_mode(m::RessacApp)
    # Ce que porte la pane focalisée prime : un synth ouvert dans PLAY (une
    # vieille disposition, un :vsplit) se travaille avec les gestes de DESIGN.
    pane = _focused_pane_impl(m)
    pane isa SynthExplorerPane && return :explore
    _focused_role(m) === :synth && return :design
    ws = current_workspace(m.workspaces)
    ws === nothing && return :play
    haskey(_MODE_OF_WORKSPACE, ws.name) && return _MODE_OF_WORKSPACE[ws.name]
    (pane isa WaveformPane || pane isa DronePane || pane isa SynthDocPane) && return :design
    return :play
end

_mode_label(mode::Symbol) = get(_WORKSPACE_OF_MODE, mode, "PLAY")

# Les scopes de touches d'un mode : déclarés avec chaque `scope!(…; modes = …)`,
# voir keymap.jl (`scope_in_mode`, `scopes_for_mode`).
_scope_in_mode(scope::Symbol, mode::Symbol) = scope_in_mode(scope, mode)

# ── Commandes par mode ────────────────────────────────────────────────
const _COMMAND_MODES = Dict{String,Tuple{Vararg{Symbol}}}()
function _command_modes!(modes::Tuple{Vararg{Symbol}}, verbs::AbstractString...)
    for v in verbs; _COMMAND_MODES[String(v)] = modes; end
    return nothing
end
_command_modes(verb::AbstractString) = get(_COMMAND_MODES, String(verb), (:play, :design, :explore))
_command_in_mode(verb::AbstractString, mode::Symbol) = mode in _command_modes(verb)

"""
    _ex_verbs_for_mode(m) -> Vector{String}

Les verbes qui ont un sens dans le mode courant (palette, complétion).
"""
_ex_verbs_for_mode(m::RessacApp) = (mode = _workspace_mode(m);
    String[v for v in _all_ex_verbs() if _command_in_mode(v, mode)])

"""
    _mode_bridge!(m, cmd) -> Bool

Une commande d'un seul autre mode emmène d'abord dans son workspace
(log) ; vrai si on a changé de workspace.
"""
function _mode_bridge!(m::RessacApp, cmd::AbstractString)
    verb = String(first(split(strip(cmd), ' ')))
    modes = _command_modes(verb)
    length(modes) == 1 || return false
    mode = _workspace_mode(m)
    mode in modes && return false
    target = _mode_label(modes[1])
    _switch_workspace_named!(m, target)
    _push_app_log!(m, "[INFO] :$verb vit dans $target — on y va")
    return true
end

_command_modes!((:play,), "tap", "tap-strict", "bpm", "tap-tempo", "piano", "piano-rec", "mixer", "mix",
                "keep", "recall", "vary", "variations", "evolve", "pats", "patterns", "patlib",
                "snip", "snippets", "snippet", "clash", "clashes", "collisions", "notes", "roll",
                "piano-roll", "slots", "rack", "now", "jump", "xfade", "add", "unmute", "unsolo",
                "starter", "tuning", "tutorial", "tour", "start")
_command_modes!((:design,), "synth", "scratch", "sandbox", "synthlib", "synth-library", "lib",
                "sculpt", "explain", "todsl", "to-dsl", "sc2dsl", "prune", "test", "note",
                "sccode", "sc", "sccode-tag", "sctag", "export", "export-synth", "tabs", "tabnext",
                "tabn", "tabprev", "tabp", "back", "sc-rediscover", "sc-cache-info", "dsl")
_command_modes!((:explore,), "harvest")
