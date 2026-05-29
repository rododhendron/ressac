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
    new_tree = _close_at(ws.tree, ws.focused_pane)
    new_tree === nothing && return   # refuse to close the last pane
    ws.tree = new_tree
    ws.focused_pane = _first_leaf_id(ws.tree)
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
