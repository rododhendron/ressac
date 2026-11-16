# src/workspace_persistence.jl
# Layout save / restore. Format: TOML with workspaces.<idx> tables
# whose `tree` field is a recursive node descriptor.

using TOML

"""
    save_layout(wm, path)

Write the manager's state to `path`. Idempotent; truncates if the
file exists. Returns nothing.
"""
function save_layout(wm::WorkspaceManager, path::AbstractString)
    mkpath(dirname(path))
    out = Dict{String,Any}()
    out["current_idx"] = wm.current_idx
    workspaces = Dict{String,Any}()
    for (i, ws) in enumerate(wm.workspaces)
        workspaces[string(i - 1)] = Dict{String,Any}(
            "name" => ws.name,
            "focused_pane" => ws.focused_pane,
            "tree" => _serialize_tree(ws.tree),
        )
    end
    out["workspaces"] = workspaces
    open(path, "w") do io
        TOML.print(io, out)
    end
    return nothing
end

function _serialize_tree(node::LayoutNode)
    if node isa PaneLeaf
        # Capture the kind of the current tab (or "editor" as a sane
        # default for an empty leaf — created by create_workspace!
        # before its first pane is installed).
        kind = "editor"
        state = Dict{String,Any}()
        if !isempty(node.tabs)
            current = node.tabs[node.current_tab]
            # Symbol → string conversion. Any plugin-registered kind
            # is stringified via lowercase of its type name (minus
            # the "Pane" suffix). Core kinds match by convention.
            kind = _kind_for(current)
            state = serialize(current)
        end
        return Dict{String,Any}(
            "type" => "pane",
            "id" => node.id,
            "kind" => kind,
            "current_tab" => node.current_tab,
            "state" => state,
        )
    else
        return Dict{String,Any}(
            "type" => "container",
            "direction" => String(node.direction),
            "ratios" => node.ratios,
            "children" => [_serialize_tree(c) for c in node.children],
        )
    end
end

_kind_for(::EditorPane) = "editor"
_kind_for(::LogPane)    = "log"
_kind_for(::DocPane)    = "doc"
_kind_for(::ScopePane)  = "scope"
# Fallback for plugin kinds: lowercase the struct's type name and strip
# any trailing "Pane" suffix. e.g. MyCustomPane → "mycustom".
function _kind_for(p::PaneImpl)
    name = String(nameof(typeof(p)))
    endswith(name, "Pane") && (name = name[1:end-4])
    return lowercase(name)
end

"""
    read_layout(path) -> WorkspaceManager

Lit une disposition sauvée dans un gestionnaire **neuf**, sans toucher à
rien d'existant. Lève — avec la raison — si le fichier manque, ne se parse
pas, ne contient aucun workspace, ou nomme un type de pane inconnu : une
disposition à moitié lue n'est jamais rendue.
"""
function read_layout(path::AbstractString)
    isfile(path) || error("fichier de disposition introuvable : $path")
    raw = try
        TOML.parsefile(path)
    catch err
        error("le fichier ne se lit pas (TOML) : " * first(sprint(showerror, err), 160))
    end
    wm = WorkspaceManager()
    workspaces_raw = get(raw, "workspaces", nothing)
    (workspaces_raw isa AbstractDict && !isempty(workspaces_raw)) ||
        error("le fichier ne contient aucun workspace")
    for k in sort(collect(keys(workspaces_raw)); by = k -> something(tryparse(Int, k), typemax(Int)))
        ws_data = workspaces_raw[k]
        (ws_data isa AbstractDict && get(ws_data, "tree", nothing) isa AbstractDict) ||
            error("le workspace « $k » n'a pas d'arbre de panes")
        tree = _deserialize_tree(ws_data["tree"], wm)
        ws = Workspace(wm.next_workspace_id, String(get(ws_data, "name", "")), tree,
                       FloatingPane[], Int(get(ws_data, "focused_pane", 1)))
        wm.next_workspace_id += 1
        push!(wm.workspaces, ws)
    end
    wm.current_idx = clamp(Int(get(raw, "current_idx", 1)), 1, length(wm.workspaces))
    return wm
end

"""
    load_layout!(wm, path) -> Bool

Remplace l'état de `wm` par la disposition de `path` — **seulement si elle
se lit en entier** (voir [`read_layout`](@ref)). En cas d'échec, `wm` est
intact, un avertissement est émis et `false` est rendu : c'est le chemin du
démarrage, où une disposition abîmée ne doit pas empêcher de jouer.
"""
function load_layout!(wm::WorkspaceManager, path::AbstractString)
    fresh = try
        read_layout(path)
    catch err
        @warn "workspace_persistence: " * sprint(showerror, err)
        return false
    end
    _adopt_layout!(wm, fresh)
    return true
end

# `wm` devient `fresh` (même objet, nouveau contenu : l'app garde sa
# référence). Les panes qui disparaissent sont fermées proprement.
function _adopt_layout!(wm::WorkspaceManager, fresh::WorkspaceManager)
    for ws in wm.workspaces
        for leaf in _all_leaves(ws.tree), tab in leaf.tabs
            try; on_close!(tab); catch; end
        end
        for f in ws.floats
            try; on_close!(f.pane); catch; end
        end
    end
    wm.workspaces = fresh.workspaces
    wm.current_idx = fresh.current_idx
    wm.next_pane_id = max(wm.next_pane_id, fresh.next_pane_id)
    wm.next_workspace_id = max(wm.next_workspace_id, fresh.next_workspace_id)
    return wm
end

function _deserialize_tree(d::AbstractDict, wm::WorkspaceManager)
    if d["type"] == "pane"
        kind = Symbol(get(d, "kind", "editor"))
        raw_state = get(d, "state", Dict{String,Any}())
        state_dict = raw_state isa AbstractDict ?
            Dict{String,Any}(String(k) => v for (k, v) in raw_state) :
            Dict{String,Any}()
        leaf_id = Int(get(d, "id", wm.next_pane_id))
        wm.next_pane_id = max(wm.next_pane_id, leaf_id + 1)
        # Un leaf sauvé VIDE (current_tab 0 : workspace jamais visité) reste
        # vide — _fill_workspace! le peuplera selon le nom du workspace.
        # Sinon exactement une pane, onglet courant 1 : jamais 0 avec une
        # pane (c'était une pane noire + BoundsError au premier rendu).
        Int(get(d, "current_tab", 1)) == 0 && return PaneLeaf(leaf_id, PaneImpl[], 0)
        pane = _pane_new(kind, state_dict)
        return PaneLeaf(leaf_id, PaneImpl[pane], 1)
    else
        direction = Symbol(d["direction"])
        ratios = collect(Float64, d["ratios"])
        children = LayoutNode[_deserialize_tree(c, wm) for c in d["children"]]
        return Container(direction, children, ratios)
    end
end

_default_layout_path() = joinpath(_config_dir(), "last_layout.toml")

_named_layout_path(name::AbstractString) =
    joinpath(_config_dir(), "layouts", "$(name).toml")
