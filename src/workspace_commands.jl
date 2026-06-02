# src/workspace_commands.jl
# Ex command handlers — invoked by the colon-command dispatcher and
# also by the keymap (pane mode short keys map to these).

function cmd_split!(wm::WorkspaceManager, kind_str::AbstractString,
                    args::AbstractDict; direction::Symbol = :h)
    ws = current_workspace(wm)
    ws === nothing && return
    kind = Symbol(kind_str)
    haskey(_PANE_KINDS, kind) || (@warn "cmd_split!: unknown kind :$kind"; return)
    new_pane = _pane_new(kind, args)
    new_leaf = PaneLeaf(wm.next_pane_id, PaneImpl[new_pane], 1)
    wm.next_pane_id += 1
    ws.tree = _split_root(ws.tree, ws.focused_pane, direction, new_leaf)
    ws.focused_pane = new_leaf.id
    return
end

# Convention from the spec keyboard model:
#   vsplit = new pane to the right (horizontal split direction)
#   hsplit = new pane below        (vertical split direction)
cmd_vsplit!(wm, kind, args) = cmd_split!(wm, kind, args; direction = :h)
cmd_hsplit!(wm, kind, args) = cmd_split!(wm, kind, args; direction = :v)

function cmd_close!(wm::WorkspaceManager)
    ws = current_workspace(wm)
    ws === nothing && return
    closing = _leaf_by_id(ws.tree, ws.focused_pane)
    new_tree = _close_at(ws.tree, ws.focused_pane)
    new_tree === nothing && return   # refuse to close the last pane
    ws.tree = new_tree
    ws.focused_pane = _first_leaf_id(ws.tree)
    # The leaf is gone from the tree — let its panes release resources
    # (e.g. a scope pane tells SC to stop emitting frames).
    if closing isa PaneLeaf
        for p in closing.tabs
            on_close!(p)
        end
    end
    return
end

function cmd_focus!(wm::WorkspaceManager, dir::Symbol)
    ws = current_workspace(wm)
    ws === nothing && return
    target = _navigate(ws.tree, ws.focused_pane, dir)
    target === nothing || (ws.focused_pane = target)
    return
end

function cmd_workspace!(wm::WorkspaceManager, op::Symbol; name::AbstractString = "")
    if op === :new
        create_workspace!(wm, name)
    elseif op === :close
        ws = current_workspace(wm)
        ws === nothing || close_workspace!(wm, ws.id)
    elseif op === :next
        isempty(wm.workspaces) ||
            (wm.current_idx = mod1(wm.current_idx + 1, length(wm.workspaces)))
    elseif op === :prev
        isempty(wm.workspaces) ||
            (wm.current_idx = mod1(wm.current_idx - 1, length(wm.workspaces)))
    end
    return
end

"""
    cmd_workspace_switch!(wm, idx)

Jump to workspace at `idx` (1-based). No-op if out of range. Bound
to Ctrl-1..9 in Task 15.
"""
function cmd_workspace_switch!(wm::WorkspaceManager, idx::Int)
    1 <= idx <= length(wm.workspaces) || return
    wm.current_idx = idx
end

"""
    cmd_workspace_named!(wm, name)

Jump to workspace by name. No-op if the name doesn't match any
workspace. Useful for `:workspace <name>` ex command.
"""
function cmd_workspace_named!(wm::WorkspaceManager, name::AbstractString)
    idx = findfirst(ws -> ws.name == name, wm.workspaces)
    idx === nothing && return
    wm.current_idx = idx
end

"""
    cmd_float!(wm)

Lift the focused pane out of the tile tree into the floats vector.
The pane's current tab becomes a single-pane FloatingPane with
default geometry (10, 5, 60×20). Refuses when the focused leaf is
the only one in the tree (would leave the workspace empty).
"""
function cmd_float!(wm::WorkspaceManager)
    ws = current_workspace(wm)
    ws === nothing && return
    # Resolve focused leaf — either the root itself or via parent
    # lookup.
    leaf = if ws.tree isa PaneLeaf && ws.tree.id == ws.focused_pane
        # Single-leaf root — refuse, can't leave the workspace empty.
        return
    else
        hit = _find_leaf_parent(ws.tree, ws.focused_pane)
        hit === nothing && return
        parent, idx = hit
        parent.children[idx]
    end
    leaf isa PaneLeaf || return
    isempty(leaf.tabs) && return
    pane = leaf.tabs[leaf.current_tab]
    z = isempty(ws.floats) ? 1 : maximum(f.z_order for f in ws.floats) + 1
    push!(ws.floats, FloatingPane(pane, 10, 5, 60, 20, z))
    new_tree = _close_at(ws.tree, leaf.id)
    new_tree === nothing && return   # safety: shouldn't happen given the guard above
    ws.tree = new_tree
    ws.focused_pane = _first_leaf_id(ws.tree)
    return
end

"""
    cmd_tile!(wm)

Move the topmost float (highest z_order) back into the tree as a
right-split of the currently focused tile pane. Reverse operation
of `cmd_float!`. No-op when there are no floats.
"""
function cmd_tile!(wm::WorkspaceManager)
    ws = current_workspace(wm)
    ws === nothing && return
    isempty(ws.floats) && return
    idx = argmax([f.z_order for f in ws.floats])
    top = ws.floats[idx]
    deleteat!(ws.floats, idx)
    new_leaf = PaneLeaf(wm.next_pane_id, PaneImpl[top.pane], 1)
    wm.next_pane_id += 1
    ws.tree = _split_root(ws.tree, ws.focused_pane, :h, new_leaf)
    ws.focused_pane = new_leaf.id
    return
end
