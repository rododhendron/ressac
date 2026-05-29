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
    load_layout!(wm, path)

Read `path` and rebuild the manager state. Falls back to a
no-op + warning on file errors or schema mismatch — the caller is
expected to install a default workspace after.
"""
function load_layout!(wm::WorkspaceManager, path::AbstractString)
    isfile(path) || begin
        @warn "workspace_persistence: layout file not found at $path"
        return nothing
    end
    raw = try
        TOML.parsefile(path)
    catch err
        @warn "workspace_persistence: parse failed: $(sprint(showerror, err))"
        return nothing
    end
    workspaces_raw = get(raw, "workspaces", Dict())
    sorted_keys = sort(collect(keys(workspaces_raw)); by = k -> parse(Int, k))
    for k in sorted_keys
        ws_data = workspaces_raw[k]
        name = String(get(ws_data, "name", ""))
        focused = Int(get(ws_data, "focused_pane", 1))
        tree = _deserialize_tree(ws_data["tree"], wm)
        ws = Workspace(wm.next_workspace_id, name, tree,
                       FloatingPane[], focused)
        wm.next_workspace_id += 1
        push!(wm.workspaces, ws)
    end
    if !isempty(wm.workspaces)
        wm.current_idx = clamp(Int(get(raw, "current_idx", 1)),
                                1, length(wm.workspaces))
    end
    return nothing
end

function _deserialize_tree(d::AbstractDict, wm::WorkspaceManager)
    if d["type"] == "pane"
        kind = Symbol(get(d, "kind", "editor"))
        raw_state = get(d, "state", Dict{String,Any}())
        state_dict = raw_state isa AbstractDict ?
            Dict{String,Any}(String(k) => v for (k, v) in raw_state) :
            Dict{String,Any}()
        pane = _pane_new(kind, state_dict)
        leaf_id = Int(get(d, "id", wm.next_pane_id))
        leaf = PaneLeaf(leaf_id, PaneImpl[pane], Int(get(d, "current_tab", 1)))
        wm.next_pane_id = max(wm.next_pane_id, leaf_id + 1)
        return leaf
    else
        direction = Symbol(d["direction"])
        ratios = collect(Float64, d["ratios"])
        children = LayoutNode[_deserialize_tree(c, wm) for c in d["children"]]
        return Container(direction, children, ratios)
    end
end

_default_layout_path() = joinpath(homedir(), ".config", "ressac", "last_layout.toml")

_named_layout_path(name::AbstractString) =
    joinpath(homedir(), ".config", "ressac", "layouts", "$(name).toml")
