# src/snippet_panes.jl
# Resolve a snippet's panes = [...] spec into a workspace layout.

"""
    _all_leaves(node) -> Vector{PaneLeaf}

Flatten the tree into a vector of leaves (depth-first order). Used
by callers needing to inspect what's currently rendered (snippet
panes test, layout introspection).
"""
function _all_leaves(node::LayoutNode, acc::Vector{PaneLeaf} = PaneLeaf[])
    if node isa PaneLeaf
        push!(acc, node)
    else
        for c in node.children
            _all_leaves(c, acc)
        end
    end
    return acc
end

# Drop the meta keys (role/side/ratio) from a pane spec so the
# remaining args are pure pane-ctor arguments.
function _spec_to_pane_args(spec::AbstractDict)
    out = Dict{String,Any}()
    for (k, v) in spec
        sk = String(k)
        sk in ("role", "side", "ratio") && continue
        out[sk] = v
    end
    return out
end

"""
    apply_snippet_panes!(wm, panes_spec, mode; snippet_name = "")

`mode` is `:starter` or `:block`. For `:starter`, rebuild the
focused workspace's tree from the spec (primary becomes root, sides
are split off). For `:block`, the current tree is unchanged — only
the `side` panes get appended; the primary's content insertion is
the caller's responsibility (editor insert at cursor).

Bad kinds warn + skip; the rest of the spec still applies.

`snippet_name` is consumed by Task 13's user-config override stack;
in Task 12 it's a noop kwarg.
"""
function apply_snippet_panes!(wm::WorkspaceManager, panes_spec::AbstractVector,
                              mode::Symbol; snippet_name::AbstractString = "")
    ws = current_workspace(wm)
    ws === nothing && return

    # User config override: if ~/.config/ressac/config.toml (loaded
    # into _RESSAC_CONFIG) defines [panes.snippets."<name>"].panes,
    # that spec wins over the plugin's. Last-wins, matching the
    # sub-project 7 convention.
    if !isempty(snippet_name)
        cfg = _RESSAC_CONFIG[]
        if haskey(cfg.panes_overrides, snippet_name)
            panes_spec = cfg.panes_overrides[snippet_name]
        end
    end

    primary_idx = findfirst(p -> String(get(p, "role", "")) == "primary",
                             panes_spec)
    if primary_idx === nothing
        @warn "snippet panes: spec has no primary; skipping apply"
        return
    end
    primary_spec = panes_spec[primary_idx]
    primary_kind = Symbol(primary_spec["kind"])
    if !haskey(_PANE_KINDS, primary_kind)
        @warn "snippet panes: primary kind ':$primary_kind' unregistered; skipping apply"
        return
    end

    if mode === :starter
        # Build the primary leaf as the new root.
        primary_args = _spec_to_pane_args(primary_spec)
        primary_pane = _pane_new(primary_kind, primary_args)
        primary_leaf = PaneLeaf(wm.next_pane_id, PaneImpl[primary_pane], 1)
        wm.next_pane_id += 1
        ws.tree = primary_leaf
        ws.focused_pane = primary_leaf.id
        for (i, spec) in enumerate(panes_spec)
            i == primary_idx && continue
            _apply_side_pane!(wm, ws, spec)
        end
    else  # :block
        for (i, spec) in enumerate(panes_spec)
            i == primary_idx && continue
            _apply_side_pane!(wm, ws, spec)
        end
        # The primary's content insertion is the caller's job: editor
        # paste-at-cursor. apply_snippet_panes! doesn't touch buffers.
    end
    return
end

function _apply_side_pane!(wm::WorkspaceManager, ws::Workspace,
                            spec::AbstractDict)
    kind = Symbol(get(spec, "kind", ""))
    if !haskey(_PANE_KINDS, kind)
        @warn "snippet panes: side kind ':$kind' unregistered; skipping"
        return
    end
    side = Symbol(get(spec, "side", "right"))
    direction = side in (:left, :right) ? :h : :v
    args = _spec_to_pane_args(spec)
    new_pane = try
        _pane_new(kind, args)
    catch err
        @warn "snippet panes: side pane construction failed: $(sprint(showerror, err))"
        return
    end
    new_leaf = PaneLeaf(wm.next_pane_id, PaneImpl[new_pane], 1)
    wm.next_pane_id += 1
    ws.tree = _split_root(ws.tree, ws.focused_pane, direction, new_leaf)
    # Focus stays on primary in starter mode (callers expect to type
    # into the primary editor); side panes are visual only.
end
