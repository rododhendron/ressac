# src/workspace_manager.jl
# Recursive layout tree + per-workspace state. The tree is N-ary
# internally (Container has ≥ 2 children) while the user-facing
# operations (split / close / navigate) maintain a vim-like binary
# mental model.

"""
    LayoutNode

Sealed sum-type for the layout tree. A node is either:
  * `PaneLeaf` — a single position in the tree, holding ≥ 1 tab
    (each tab is a `PaneImpl`)
  * `Container` — a horizontal or vertical arrangement of children
"""
abstract type LayoutNode end

mutable struct PaneLeaf <: LayoutNode
    id::Int
    tabs::Vector{PaneImpl}
    current_tab::Int
end

mutable struct Container <: LayoutNode
    direction::Symbol        # :h | :v
    children::Vector{LayoutNode}
    ratios::Vector{Float64}
end

mutable struct FloatingPane
    pane::PaneImpl
    x::Int; y::Int
    w::Int; h::Int
    z_order::Int
end

mutable struct Workspace
    id::Int
    name::String
    tree::LayoutNode
    floats::Vector{FloatingPane}
    focused_pane::Int
end

mutable struct WorkspaceManager
    workspaces::Vector{Workspace}
    current_idx::Int
    next_pane_id::Int
    next_workspace_id::Int
end

WorkspaceManager() = WorkspaceManager(Workspace[], 0, 1, 1)

# ── Tree operations ────────────────────────────────────────────────

"""
    _find_leaf_parent(root, leaf_id) -> (parent, index) or nothing

Locate the `Container` that directly contains the `PaneLeaf` with
the given id, and the leaf's index within `parent.children`. Returns
`nothing` if the leaf is the root itself or absent.
"""
function _find_leaf_parent(node::LayoutNode, leaf_id::Int,
                           parent::Union{Nothing,Container} = nothing)
    if node isa PaneLeaf
        if node.id == leaf_id
            idx = parent === nothing ? 0 :
                  findfirst(c -> c === node, parent.children)
            return (parent, idx)
        end
        return nothing
    end
    # Container — recurse.
    for child in node.children
        hit = _find_leaf_parent(child, leaf_id, node)
        hit === nothing || return hit
    end
    return nothing
end

"""
    _split_at!(container, child_idx, direction, new_leaf)

Insert `new_leaf` as a sibling of `container.children[child_idx]`.
If `direction == container.direction`, append as a sibling and
recompute equal ratios. If different, wrap the existing child in a
new container of `direction`.
"""
function _split_at!(container::Container, child_idx::Int,
                    direction::Symbol, new_leaf::PaneLeaf)
    if direction === container.direction
        insert!(container.children, child_idx + 1, new_leaf)
        n = length(container.children)
        container.ratios = fill(1.0 / n, n)
    else
        old_child = container.children[child_idx]
        sub = Container(direction, LayoutNode[old_child, new_leaf], [0.5, 0.5])
        container.children[child_idx] = sub
    end
    return container
end

"""
    _split_root(root, leaf_id, direction, new_leaf) -> LayoutNode

Top-level split that handles the root being the target leaf.
Returns the new root (may differ from input when wrapping).
"""
function _split_root(root::LayoutNode, leaf_id::Int,
                     direction::Symbol, new_leaf::PaneLeaf)
    if root isa PaneLeaf && root.id == leaf_id
        return Container(direction, LayoutNode[root, new_leaf], [0.5, 0.5])
    end
    if root isa Container
        hit = _find_leaf_parent(root, leaf_id)
        if hit !== nothing
            parent, idx = hit
            _split_at!(parent, idx, direction, new_leaf)
        end
    end
    return root
end

"""
    _close_at(root, leaf_id) -> LayoutNode | Nothing

Remove the leaf with the given id. Collapses unary containers
(a container with one remaining child becomes that child). Returns
the new root, or `nothing` if the only leaf is removed.
"""
function _close_at(root::LayoutNode, leaf_id::Int)
    if root isa PaneLeaf
        return root.id == leaf_id ? nothing : root
    end
    # Container
    new_children = LayoutNode[]
    for c in root.children
        if c isa PaneLeaf && c.id == leaf_id
            continue
        end
        rc = _close_at(c, leaf_id)
        rc === nothing || push!(new_children, rc)
    end
    isempty(new_children) && return nothing
    if length(new_children) == 1
        return new_children[1]   # collapse unary
    end
    n = length(new_children)
    return Container(root.direction, new_children, fill(1.0 / n, n))
end

"""
    _navigate(root, leaf_id, dir) -> Int | Nothing

Find the leaf ID adjacent to `leaf_id` in the given direction
(`:left`, `:right`, `:up`, `:down`). Returns `nothing` if no
adjacent leaf exists (edge of the tree).
"""
function _navigate(root::LayoutNode, leaf_id::Int, dir::Symbol)
    axis = dir in (:left, :right) ? :h : :v
    delta = dir in (:right, :down) ? 1 : -1

    path = _path_to_leaf(root, leaf_id)
    path === nothing && return nothing
    # Walk up the path looking for a Container of matching axis.
    for i in length(path):-1:1
        node = path[i]
        if node isa Container && node.direction === axis
            i == length(path) && continue
            child_idx = findfirst(c -> c === path[i+1], node.children)
            target_idx = child_idx + delta
            if 1 <= target_idx <= length(node.children)
                return _first_leaf_id(node.children[target_idx])
            end
        end
    end
    return nothing
end

function _path_to_leaf(node::LayoutNode, leaf_id::Int,
                       acc::Vector{LayoutNode} = LayoutNode[])
    push!(acc, node)
    if node isa PaneLeaf
        node.id == leaf_id && return copy(acc)
        pop!(acc); return nothing
    end
    for child in node.children
        r = _path_to_leaf(child, leaf_id, acc)
        r === nothing || return r
    end
    pop!(acc); return nothing
end

function _first_leaf_id(node::LayoutNode)
    node isa PaneLeaf && return node.id
    return _first_leaf_id(node.children[1])
end

"""
    _compute_rects(root, area) -> Dict{Int, NamedTuple}

Compute a (x, y, w, h) rect for every leaf in the tree, given the
overall `area`. Used by `view()` to know where to render each pane.
"""
function _compute_rects(root::LayoutNode, area::NamedTuple)
    out = Dict{Int, NamedTuple}()
    _fill_rects!(root, area, out)
    return out
end

function _fill_rects!(node::LayoutNode, area::NamedTuple, out::Dict)
    if node isa PaneLeaf
        out[node.id] = area
        return
    end
    if node.direction === :h
        x = area.x
        for (i, child) in enumerate(node.children)
            w = round(Int, area.w * node.ratios[i])
            sub_area = (x=x, y=area.y, w=w, h=area.h)
            _fill_rects!(child, sub_area, out)
            x += w
        end
    else
        y = area.y
        for (i, child) in enumerate(node.children)
            h = round(Int, area.h * node.ratios[i])
            sub_area = (x=area.x, y=y, w=area.w, h=h)
            _fill_rects!(child, sub_area, out)
            y += h
        end
    end
end
