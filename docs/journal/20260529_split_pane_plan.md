# Split-pane UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Ressac's fixed-rect TUI (`m.layout_patterns`, `m.layout_synth`, `m.layout_logs`, `m.layout_scope`) with a recursive split-pane system: workspaces at the top level, N-ary containers + tabs + floating panes, every UI surface as a plugin-extensible `PaneImpl`.

**Architecture:** Six core types — `PaneImpl` (abstract, 4 mandatory + 8 defaulted fns), `_PANE_KINDS` registry (plugins call `register_pane_kind!`), `LayoutNode` (`PaneLeaf` | `Container`), `Workspace`, `FloatingPane`, `WorkspaceManager`. Ressac core dogfoods the registry by registering 4 kinds (`:editor` unifying patterns+synth, `:log`, `:scope`, `:doc`). 14-step incremental migration preserves all existing behavior; deferred to sub-project 10: modal → float migration.

**Tech Stack:** Julia 1.10+, Tachikoma 2.1+ (existing TUI engine — `TK.Model`, `TK.Rect`, `TK.Buffer`, `TK.KeyEvent`, `TK.view`, `TK.update!`), existing `TOML` stdlib (layout persistence), the sub-project 7 docs/snippets registry (consumed by `:doc` kind + snippet `panes = [...]` resolution).

---

## File structure

**New source files:**
- `src/pane_interface.jl` — abstract `PaneImpl`, 12-fn contract with defaults, `_PANE_KINDS` registry, `register_pane_kind!`, `_pane_new`
- `src/workspace_manager.jl` — `LayoutNode`, `PaneLeaf`, `Container`, `FloatingPane`, `Workspace`, `WorkspaceManager`, tree ops (`_split_at!`, `_close_at!`, `_navigate`, `_collapse_unary!`, `_compute_rects`)
- `src/workspace_persistence.jl` — `_save_layout`, `_load_layout`, `_default_workspace`, named layouts under `~/.config/ressac/layouts/`
- `src/workspace_commands.jl` — ex command handlers (`:split`, `:vsplit`, `:focus`, `:close`, `:resize`, `:workspace`, `:layout`, `:tile`, `:float`, `:zoom`)
- `src/workspace_keymap.jl` — pane mode + resize mode state + dispatch table
- `src/pane_editor.jl` — `:editor` `PaneImpl` (unified patterns + synth, role-per-buffer)
- `src/pane_log.jl` — `:log` `PaneImpl`
- `src/pane_doc.jl` — `:doc` `PaneImpl` (reads `Ressac.lookup_doc`)
- `src/pane_scope.jl` — `:scope` `PaneImpl` with subtype state
- `test/test_pane_interface.jl`
- `test/test_workspace_manager.jl`
- `test/test_workspace_persistence.jl`
- `test/test_workspace_commands.jl`
- `test/test_snippet_panes_apply.jl`
- `test/fixtures/layouts/sample_layout.toml`

**Modified source files:**
- `src/Ressac.jl` — `include` chain for the new files (after `extension_registry.jl`, before `tui_app.jl`)
- `src/tui_app.jl` — `RessacApp` struct gains `workspaces::WorkspaceManager`, `view(m, frame)` switches to `WorkspaceManager` rendering; drops the 5 `layout_*` fields in the final cleanup task
- `test/runtests.jl` — `include` the 5 new test files

---

## Phase 1 — Foundation

### Task 1: `PaneImpl` abstract type + registry

**Files:**
- Create: `src/pane_interface.jl`
- Create: `test/test_pane_interface.jl`
- Modify: `src/Ressac.jl`
- Modify: `test/runtests.jl`

- [ ] **Step 1: Write the failing tests**

`test/test_pane_interface.jl`:
```julia
using Test
using Ressac

# Minimal kind used to exercise the contract from outside Main.
struct _NullPane <: Ressac.PaneImpl end
Ressac.render!(::_NullPane, ::Any, ::Any) = nothing
Ressac.handle_key!(::_NullPane, ::Any) = false
Ressac.title(::_NullPane) = "null"

@testset "pane_interface" begin
    @testset "register_pane_kind! + _pane_new round-trip" begin
        empty!(Ressac._PANE_KINDS)
        Ressac.register_pane_kind!(:null, args -> _NullPane())
        p = Ressac._pane_new(:null, Dict{String,Any}())
        @test p isa _NullPane
        @test Ressac.title(p) == "null"
    end

    @testset "register_pane_kind! shadow warning on conflict" begin
        empty!(Ressac._PANE_KINDS)
        Ressac.register_pane_kind!(:dup, args -> _NullPane())
        @test_logs (:warn, r"shadowed") begin
            Ressac.register_pane_kind!(:dup, args -> _NullPane())
        end
    end

    @testset "_pane_new on unregistered kind throws ArgumentError" begin
        empty!(Ressac._PANE_KINDS)
        @test_throws ArgumentError Ressac._pane_new(:ghost, Dict{String,Any}())
    end

    @testset "defaults — default_mode is :tile" begin
        empty!(Ressac._PANE_KINDS)
        Ressac.register_pane_kind!(:null, args -> _NullPane())
        p = Ressac._pane_new(:null, Dict{String,Any}())
        @test Ressac.default_mode(p) === :tile
        @test Ressac.serialize(p) == Dict{String,Any}()
        @test Ressac.can_split(p) === true
        @test Ressac.preferred_size(p) === nothing
        @test Ressac.sidebar(p) == String[]
        @test Ressac.handle_mouse!(p, nothing) === false
        @test Ressac.on_focus!(p) === nothing
        @test Ressac.on_blur!(p) === nothing
        @test Ressac.on_close!(p) === nothing
    end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: `UndefVarError: PaneImpl not defined in Ressac` or similar.

- [ ] **Step 3: Create `pane_interface.jl`**

```julia
# src/pane_interface.jl
# Abstract pane type + plugin-extensible registry. Every UI surface
# in the new split-pane system is a PaneImpl. See
# docs/journal/20260529_split_pane_design.md for the design.

"""
    PaneImpl

Abstract supertype for every kind of pane (editor, log, scope, doc,
plugin-contributed kinds). A concrete kind must implement 4
mandatory methods (`render!`, `handle_key!`, `title`,
plus a constructor registered via `register_pane_kind!`) and may
override 8 defaulted ones.
"""
abstract type PaneImpl end

# ── Mandatory contract ─────────────────────────────────────────────
"""
    render!(p, area, buf)

Draw the pane inside `area` into the Tachikoma render `buf`.
"""
function render! end

"""
    handle_key!(p, evt) -> Bool

Process a key event. Return `true` if the pane consumed the event
(stops further dispatch). Return `false` for the workspace manager
to keep routing.
"""
function handle_key! end

"""
    title(p) -> String

Short label shown in tab strips, borders, status hints.
"""
function title end

# ── Defaulted contract ─────────────────────────────────────────────
"""
    default_mode(p) -> Symbol

`:tile` or `:float`. Override only for kinds that should float by
default (e.g. transient pickers in future sub-projects).
"""
default_mode(::PaneImpl) = :tile

"""
    serialize(p) -> Dict{String,Any}

State captured for the layout persistence file. Empty by default;
override for kinds that should restore their state on next boot
(e.g. scope subtype, doc ref, editor tab list).
"""
serialize(::PaneImpl) = Dict{String,Any}()

on_focus!(::PaneImpl)  = nothing
on_blur!(::PaneImpl)   = nothing
on_close!(::PaneImpl)  = nothing

handle_mouse!(::PaneImpl, ::Any) = false
preferred_size(::PaneImpl) = nothing
can_split(::PaneImpl) = true
sidebar(::PaneImpl) = String[]

# ── Registry ───────────────────────────────────────────────────────
"""
    _PANE_KINDS

Symbol → constructor (`Dict -> PaneImpl`). Populated by
`register_pane_kind!`. Ressac core registers its 4 kinds at boot;
plugins register theirs from their `[julia]` init code.
"""
const _PANE_KINDS = Dict{Symbol,Function}()

"""
    register_pane_kind!(name, ctor)

Register `ctor(args::Dict)::PaneImpl` under `name`. Shadowing an
existing entry emits a warning but is allowed (so plugins can
override core deliberately, matching the sub-project 7 convention).
"""
function register_pane_kind!(name::Symbol, ctor::Function)
    if haskey(_PANE_KINDS, name)
        @warn "pane kind '$name' shadowed by new registration"
    end
    _PANE_KINDS[name] = ctor
    return name
end

"""
    _pane_new(kind, args) -> PaneImpl

Instantiate a pane via the registered constructor. Throws
`ArgumentError` when the kind isn't registered.
"""
function _pane_new(kind::Symbol, args::AbstractDict)
    ctor = get(_PANE_KINDS, kind, nothing)
    ctor === nothing &&
        throw(ArgumentError("pane kind '$kind' is not registered"))
    return ctor(args)
end

list_pane_kinds() = sort!(collect(keys(_PANE_KINDS)))
```

- [ ] **Step 4: Wire into Ressac.jl**

In `src/Ressac.jl`, find the line `include("extension_registry.jl")` and insert AFTER it:

```julia
# ─── Pane interface — sub-project 9 foundation ─────────────────────
include("pane_interface.jl")
```

- [ ] **Step 5: Wire test into runtests.jl**

In `test/runtests.jl`, after `include("test_sc_autodiscover.jl")`:
```julia
    include("test_pane_interface.jl")
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: `Test Summary: | Pass  Total   Time` with all-green, around 1551+ assertions.

- [ ] **Step 7: Commit**

```bash
git add src/pane_interface.jl src/Ressac.jl test/test_pane_interface.jl test/runtests.jl
git commit -m "$(cat <<'EOF'
feat(panes): PaneImpl abstract type + _PANE_KINDS registry

Foundation for sub-project 9 — every UI surface becomes a PaneImpl
with 4 mandatory functions (render!, handle_key!, title, ctor) plus
8 defaulted ones. register_pane_kind! mirrors the sub-project 7
registry convention (last-wins with warning).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `LayoutNode` types + tree operations

**Files:**
- Create: `src/workspace_manager.jl`
- Create: `test/test_workspace_manager.jl`
- Modify: `src/Ressac.jl`
- Modify: `test/runtests.jl`

- [ ] **Step 1: Write the failing tests**

Create `test/test_workspace_manager.jl`:
```julia
using Test
using Ressac

# Reuse the _NullPane defined in test_pane_interface.jl if loaded;
# otherwise define a local one. Either way it's a leaf-content stub.
if !isdefined(Main, :_NullPane)
    struct _NullPane <: Ressac.PaneImpl end
    Ressac.render!(::_NullPane, ::Any, ::Any) = nothing
    Ressac.handle_key!(::_NullPane, ::Any) = false
    Ressac.title(::_NullPane) = "null"
end

@testset "workspace_manager — tree ops" begin
    @testset "PaneLeaf construction has one tab + current_tab=1" begin
        leaf = Ressac.PaneLeaf(1, [_NullPane()], 1)
        @test leaf.id == 1
        @test length(leaf.tabs) == 1
        @test leaf.current_tab == 1
    end

    @testset "Container has direction + children + ratios" begin
        a = Ressac.PaneLeaf(1, [_NullPane()], 1)
        b = Ressac.PaneLeaf(2, [_NullPane()], 1)
        c = Ressac.Container(:h, Ressac.LayoutNode[a, b], [0.5, 0.5])
        @test c.direction === :h
        @test length(c.children) == 2
        @test c.ratios ≈ [0.5, 0.5]
    end

    @testset "_split_at! inserts sibling in matching-direction container" begin
        # Container(:h, [a, b]) — splitting `a` to the right adds a sibling at index 2.
        a = Ressac.PaneLeaf(1, [_NullPane()], 1)
        b = Ressac.PaneLeaf(2, [_NullPane()], 1)
        root = Ressac.Container(:h, Ressac.LayoutNode[a, b], [0.5, 0.5])
        new_leaf = Ressac.PaneLeaf(3, [_NullPane()], 1)
        Ressac._split_at!(root, 1, :h, new_leaf)
        @test length(root.children) == 3
        @test root.children[2] === new_leaf
        @test root.ratios ≈ [0.333, 0.333, 0.333] atol=0.01
    end

    @testset "_split_at! wraps leaf when direction differs" begin
        # Standalone leaf, no parent — split creates a Container.
        a = Ressac.PaneLeaf(1, [_NullPane()], 1)
        root_ref = Ref{Ressac.LayoutNode}(a)
        new_leaf = Ressac.PaneLeaf(2, [_NullPane()], 1)
        new_root = Ressac._split_root(root_ref[], 1, :v, new_leaf)
        @test new_root isa Ressac.Container
        @test new_root.direction === :v
        @test length(new_root.children) == 2
        @test new_root.children[1] === a
        @test new_root.children[2] === new_leaf
    end

    @testset "_close_at! removes leaf + collapses unary container" begin
        a = Ressac.PaneLeaf(1, [_NullPane()], 1)
        b = Ressac.PaneLeaf(2, [_NullPane()], 1)
        root = Ressac.Container(:h, Ressac.LayoutNode[a, b], [0.5, 0.5])
        new_root = Ressac._close_at(root, 2)
        # b removed → container has only one child → collapse to that leaf.
        @test new_root === a
    end

    @testset "_navigate :right within a horizontal container" begin
        a = Ressac.PaneLeaf(1, [_NullPane()], 1)
        b = Ressac.PaneLeaf(2, [_NullPane()], 1)
        root = Ressac.Container(:h, Ressac.LayoutNode[a, b], [0.5, 0.5])
        @test Ressac._navigate(root, 1, :right) == 2
        @test Ressac._navigate(root, 2, :right) === nothing   # nothing further right
    end

    @testset "_compute_rects partitions area by ratios" begin
        a = Ressac.PaneLeaf(1, [_NullPane()], 1)
        b = Ressac.PaneLeaf(2, [_NullPane()], 1)
        root = Ressac.Container(:h, Ressac.LayoutNode[a, b], [0.6, 0.4])
        area = (x=0, y=0, w=100, h=20)
        rects = Ressac._compute_rects(root, area)
        @test rects[1] == (x=0,  y=0, w=60, h=20)
        @test rects[2] == (x=60, y=0, w=40, h=20)
    end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`

Expected: `UndefVarError: PaneLeaf not defined in Ressac`.

- [ ] **Step 3: Create `workspace_manager.jl`**

```julia
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
        node.id == leaf_id && return (parent, parent === nothing ? 0 :
                                       findfirst(c -> c === node, parent.children))
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
        # Replace the child with a new sub-container.
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
    # Find the leaf's "sibling lineage": walk up to find a container
    # whose direction matches the navigation axis, then pick the
    # child immediately before/after the current one.
    axis = dir in (:left, :right) ? :h : :v
    delta = dir in (:right, :down) ? 1 : -1

    path = _path_to_leaf(root, leaf_id)
    path === nothing && return nothing
    # Walk up the path looking for a Container of matching axis.
    for i in length(path):-1:1
        node = path[i]
        if node isa Container && node.direction === axis
            child_idx = if i == length(path)
                # Shouldn't happen — the leaf isn't a Container, but guard.
                continue
            else
                findfirst(c -> c === path[i+1], node.children)
            end
            target_idx = child_idx + delta
            if 1 <= target_idx <= length(node.children)
                # Descend into target_idx's subtree, prefer first leaf.
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
    # Container
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
```

- [ ] **Step 4: Wire into Ressac.jl**

In `src/Ressac.jl`, after `include("pane_interface.jl")`:
```julia
include("workspace_manager.jl")
```

- [ ] **Step 5: Wire test into runtests.jl**

After `include("test_pane_interface.jl")`:
```julia
    include("test_workspace_manager.jl")
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add src/workspace_manager.jl src/Ressac.jl test/test_workspace_manager.jl test/runtests.jl
git commit -m "$(cat <<'EOF'
feat(panes): LayoutNode tree + split/close/navigate/compute_rects

Six types — LayoutNode, PaneLeaf, Container, FloatingPane,
Workspace, WorkspaceManager — plus the core tree operations.
N-ary internally; user-facing split treats binary direction. Close
collapses unary containers. Navigate walks the path-to-leaf looking
for a matching-axis container.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `WorkspaceManager` create/destroy/switch

**Files:**
- Modify: `src/workspace_manager.jl` (append helpers)
- Modify: `test/test_workspace_manager.jl` (append testset)

- [ ] **Step 1: Add failing tests**

Append to `test/test_workspace_manager.jl`:
```julia
@testset "workspace_manager — workspace ops" begin
    @testset "create_workspace! adds workspace + switches focus" begin
        wm = Ressac.WorkspaceManager()
        ws_id = Ressac.create_workspace!(wm, "live")
        @test length(wm.workspaces) == 1
        @test wm.current_idx == 1
        @test wm.workspaces[1].name == "live"
        @test wm.workspaces[1].id == ws_id
    end

    @testset "close_workspace! removes + reassigns current_idx" begin
        wm = Ressac.WorkspaceManager()
        a = Ressac.create_workspace!(wm, "a")
        b = Ressac.create_workspace!(wm, "b")
        @test wm.current_idx == 2
        Ressac.close_workspace!(wm, b)
        @test length(wm.workspaces) == 1
        @test wm.current_idx == 1
        @test wm.workspaces[1].name == "a"
    end

    @testset "switch_workspace! by index" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "a")
        Ressac.create_workspace!(wm, "b")
        Ressac.create_workspace!(wm, "c")
        Ressac.switch_workspace!(wm, 1)
        @test wm.current_idx == 1
        Ressac.switch_workspace!(wm, 3)
        @test wm.current_idx == 3
        @test_throws BoundsError Ressac.switch_workspace!(wm, 99)
    end

    @testset "current_workspace returns the focused one" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "a")
        Ressac.create_workspace!(wm, "b")
        Ressac.switch_workspace!(wm, 1)
        @test Ressac.current_workspace(wm).name == "a"
    end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`

Expected: `UndefVarError: create_workspace! not defined`.

- [ ] **Step 3: Append workspace ops to `workspace_manager.jl`**

```julia
# ── Workspace lifecycle ────────────────────────────────────────────

"""
    create_workspace!(wm, name="") -> Int

Create a new workspace with a single empty `PaneLeaf` (no tabs,
no pane content). Returns the workspace's id. Switches focus to
the new workspace.

The empty leaf is a placeholder; the caller is expected to install
a pane via the snippet `panes = [...]` application or a manual
`:split` command.
"""
function create_workspace!(wm::WorkspaceManager, name::AbstractString = "")
    ws_id = wm.next_workspace_id
    leaf_id = wm.next_pane_id
    wm.next_workspace_id += 1
    wm.next_pane_id += 1
    leaf = PaneLeaf(leaf_id, PaneImpl[], 0)
    ws = Workspace(ws_id, String(name), leaf, FloatingPane[], leaf_id)
    push!(wm.workspaces, ws)
    wm.current_idx = length(wm.workspaces)
    return ws_id
end

"""
    close_workspace!(wm, ws_id)

Remove the workspace identified by `ws_id`. If it was the current
one, focus the previous (or first if it was first).
"""
function close_workspace!(wm::WorkspaceManager, ws_id::Int)
    idx = findfirst(ws -> ws.id == ws_id, wm.workspaces)
    idx === nothing && return
    deleteat!(wm.workspaces, idx)
    if isempty(wm.workspaces)
        wm.current_idx = 0
    else
        wm.current_idx = clamp(idx == 1 ? 1 : idx - 1, 1, length(wm.workspaces))
    end
    return nothing
end

"""
    switch_workspace!(wm, idx)

Focus workspace at `idx` (1-based). Throws `BoundsError` if out of
range.
"""
function switch_workspace!(wm::WorkspaceManager, idx::Int)
    1 <= idx <= length(wm.workspaces) || throw(BoundsError(wm.workspaces, idx))
    wm.current_idx = idx
    return nothing
end

current_workspace(wm::WorkspaceManager) =
    wm.current_idx == 0 ? nothing : wm.workspaces[wm.current_idx]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add src/workspace_manager.jl test/test_workspace_manager.jl
git commit -m "$(cat <<'EOF'
feat(panes): WorkspaceManager create/close/switch + current_workspace

Lifecycle for the top-level workspace container. Creates start
with a placeholder empty PaneLeaf — callers install panes via
snippet panes = [...] application or :split commands.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — Core kinds

### Task 4: `:editor` kind (unified patterns + synth)

**Files:**
- Create: `src/pane_editor.jl`
- Modify: `src/Ressac.jl`
- Modify: `test/test_pane_interface.jl` (extend with editor-specific assertions)

This task is intentionally the largest of the kind tasks because of the unification work. The other 3 kind tasks (Tasks 5, 6, 7) follow the same shape but are smaller.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_pane_interface.jl`:
```julia
@testset "pane_editor — :editor kind" begin
    @testset "registered + constructible from args" begin
        ep = Ressac._pane_new(:editor, Dict{String,Any}(
            "buffer_role" => "patterns",
            "name"        => "main",
        ))
        @test ep isa Ressac.EditorPane
        @test length(ep.tabs) == 1
        @test ep.tabs[1].role === :patterns
        @test ep.tabs[1].name == "main"
        @test Ressac.title(ep) == "main"   # falls back to current tab's name
    end

    @testset "default_mode === :tile" begin
        ep = Ressac._pane_new(:editor, Dict{String,Any}())
        @test Ressac.default_mode(ep) === :tile
    end

    @testset "buffer_role defaults to :patterns when not specified" begin
        ep = Ressac._pane_new(:editor, Dict{String,Any}())
        @test ep.tabs[1].role === :patterns
    end

    @testset "serialize captures tab list + current_tab + roles" begin
        ep = Ressac._pane_new(:editor, Dict{String,Any}(
            "buffer_role" => "synth", "name" => "wob1",
        ))
        s = Ressac.serialize(ep)
        @test haskey(s, "tabs")
        @test length(s["tabs"]) == 1
        @test s["tabs"][1]["role"] == "synth"
        @test s["tabs"][1]["name"] == "wob1"
        @test s["current_tab"] == 1
    end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`

Expected: `UndefVarError: EditorPane not defined`.

- [ ] **Step 3: Create `pane_editor.jl`**

```julia
# src/pane_editor.jl
# :editor pane — unified patterns + synth editor with role-per-buffer.
#
# Each tab is an EditorBuffer with a role (:patterns | :synth) that
# determines:
#   * eval target (slot scheduler vs SC eval)
#   * completion context (patterns DSL vs UGens/SynthDSL)
#   * which key bindings dispatch (`e` vs `T`)
#
# Sub-project 9 ships the pane skeleton + 4 contract fns + role
# routing. The actual editor cursor / autocomplete / vim modal logic
# reuses the existing code in tui_app.jl (Tachikoma text buffer).
# Step 7 of the migration plan swaps the m.editor field out for an
# EditorPane wrapper.

struct EditorBuffer
    content::String
    cursor_row::Int
    cursor_col::Int
    scroll_offset::Int
    role::Symbol            # :patterns | :synth
    name::String
    eval_target::Symbol     # :slot | :sc_eval
    completion_ctx::Symbol  # :patterns_dsl | :synth_dsl | :sc_ugens
end

function EditorBuffer(; role::Symbol = :patterns,
                       name::AbstractString = "main",
                       content::AbstractString = "")
    eval_target, completion_ctx = if role === :synth
        (:sc_eval, :synth_dsl)
    else
        (:slot, :patterns_dsl)
    end
    return EditorBuffer(String(content), 1, 0, 0, role, String(name),
                        eval_target, completion_ctx)
end

mutable struct EditorPane <: PaneImpl
    tabs::Vector{EditorBuffer}
    current_tab::Int
end

EditorPane() = EditorPane([EditorBuffer()], 1)

function _editor_pane_ctor(args::AbstractDict)
    role_str = String(get(args, "buffer_role", "patterns"))
    name_str = String(get(args, "name", "main"))
    role = role_str == "synth" ? :synth : :patterns
    buf = EditorBuffer(; role = role, name = name_str)
    return EditorPane([buf], 1)
end

# ── PaneImpl contract ──────────────────────────────────────────────

# Mandatory: render!, handle_key!, title.
# Step 7 of the migration plan will wire render! to the existing
# Tachikoma text buffer rendering. For Task 4, we provide a stub
# that the unit tests don't exercise — the contract is satisfied.

render!(::EditorPane, area, buf) = nothing       # filled in step 7
handle_key!(::EditorPane, evt) = false           # filled in step 7

function title(p::EditorPane)
    1 <= p.current_tab <= length(p.tabs) || return "(empty editor)"
    return p.tabs[p.current_tab].name
end

# Defaulted overrides
default_mode(::EditorPane) = :tile

function serialize(p::EditorPane)
    return Dict{String,Any}(
        "tabs" => [Dict{String,Any}(
            "role" => String(t.role),
            "name" => t.name,
            "content" => t.content,
            "cursor_row" => t.cursor_row,
            "cursor_col" => t.cursor_col,
            "scroll_offset" => t.scroll_offset,
        ) for t in p.tabs],
        "current_tab" => p.current_tab,
    )
end

# ── Registration ───────────────────────────────────────────────────
register_pane_kind!(:editor, _editor_pane_ctor)
```

- [ ] **Step 4: Wire into Ressac.jl**

After `include("workspace_manager.jl")`:
```julia
include("pane_editor.jl")
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add src/pane_editor.jl src/Ressac.jl test/test_pane_interface.jl
git commit -m "$(cat <<'EOF'
feat(panes): :editor kind unifying patterns + synth via per-buffer role

EditorBuffer carries (role, name, eval_target, completion_ctx).
EditorPane holds an ordered vector of buffers + current_tab index.
serialize captures full state for layout persistence.

render! and handle_key! are stubs until step 7 of the migration
plan rewires them to Tachikoma's existing text editor pipeline.
The pane contract is satisfied; the kind is constructible.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `:log` kind

**Files:**
- Create: `src/pane_log.jl`
- Modify: `src/Ressac.jl`
- Modify: `test/test_pane_interface.jl`

- [ ] **Step 1: Add failing tests**

Append to `test/test_pane_interface.jl`:
```julia
@testset "pane_log — :log kind" begin
    @testset "registered + constructible" begin
        lp = Ressac._pane_new(:log, Dict{String,Any}())
        @test lp isa Ressac.LogPane
        @test Ressac.title(lp) == "log"
        @test Ressac.default_mode(lp) === :tile
    end

    @testset "serialize returns empty (global log is shared state)" begin
        lp = Ressac._pane_new(:log, Dict{String,Any}())
        @test Ressac.serialize(lp) == Dict{String,Any}()
    end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: `UndefVarError: LogPane not defined`.

- [ ] **Step 3: Create `pane_log.jl`**

```julia
# src/pane_log.jl
# :log pane — renders the global _APP_LOG ring buffer.
# State is global, so serialize returns {}.

mutable struct LogPane <: PaneImpl
    scroll::Int
end

LogPane() = LogPane(0)
_log_pane_ctor(::AbstractDict) = LogPane()

render!(::LogPane, area, buf) = nothing        # wired in step 7
handle_key!(::LogPane, evt) = false            # wired in step 7
title(::LogPane) = "log"

register_pane_kind!(:log, _log_pane_ctor)
```

- [ ] **Step 4: Wire into Ressac.jl**

After `include("pane_editor.jl")`:
```julia
include("pane_log.jl")
```

- [ ] **Step 5: Run tests + commit**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Then:
```bash
git add src/pane_log.jl src/Ressac.jl test/test_pane_interface.jl
git commit -m "$(cat <<'EOF'
feat(panes): :log kind — renders the global _APP_LOG

Trivial kind: state-free (global log is shared), default tile.
render! and handle_key! stubbed until step 7.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `:doc` kind

**Files:**
- Create: `src/pane_doc.jl`
- Modify: `src/Ressac.jl`
- Modify: `test/test_pane_interface.jl`

- [ ] **Step 1: Add failing tests**

Append to `test/test_pane_interface.jl`:
```julia
@testset "pane_doc — :doc kind" begin
    @testset "registered + constructible with ref" begin
        dp = Ressac._pane_new(:doc, Dict{String,Any}("ref" => "gain"))
        @test dp isa Ressac.DocPane
        @test dp.name == "gain"
        @test Ressac.title(dp) == "doc:gain"
    end

    @testset "default ref is empty when not specified" begin
        dp = Ressac._pane_new(:doc, Dict{String,Any}())
        @test dp.name == ""
        @test Ressac.title(dp) == "doc"
    end

    @testset "serialize captures the ref name" begin
        dp = Ressac._pane_new(:doc, Dict{String,Any}("ref" => "SinOsc"))
        @test Ressac.serialize(dp) == Dict{String,Any}(
            "name" => "SinOsc", "scroll" => 0,
        )
    end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: `UndefVarError: DocPane not defined`.

- [ ] **Step 3: Create `pane_doc.jl`**

```julia
# src/pane_doc.jl
# :doc pane — renders a DocEntry from the sub-project 7 registry.

mutable struct DocPane <: PaneImpl
    name::String              # the DocEntry name (registry key)
    scroll::Int
end

function _doc_pane_ctor(args::AbstractDict)
    return DocPane(String(get(args, "ref", "")), 0)
end

render!(::DocPane, area, buf) = nothing        # wired in step 7
handle_key!(::DocPane, evt) = false            # wired in step 7
title(p::DocPane) = isempty(p.name) ? "doc" : "doc:$(p.name)"

serialize(p::DocPane) = Dict{String,Any}("name" => p.name, "scroll" => p.scroll)

register_pane_kind!(:doc, _doc_pane_ctor)
```

- [ ] **Step 4: Wire into Ressac.jl + run + commit**

After `include("pane_log.jl")`:
```julia
include("pane_doc.jl")
```

Run tests then:
```bash
git add src/pane_doc.jl src/Ressac.jl test/test_pane_interface.jl
git commit -m "$(cat <<'EOF'
feat(panes): :doc kind — reads DocEntry from sub-project 7 registry

Holds a ref to a registered doc name + scroll position. Constructible
from snippet panes = [{kind = "doc", ref = "SinOsc"}, …]. render! +
handle_key! stubbed until step 7.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `:scope` kind with subtype

**Files:**
- Create: `src/pane_scope.jl`
- Modify: `src/Ressac.jl`
- Modify: `test/test_pane_interface.jl`

- [ ] **Step 1: Add failing tests**

Append to `test/test_pane_interface.jl`:
```julia
@testset "pane_scope — :scope kind" begin
    @testset "registered with default subtype :wave" begin
        sp = Ressac._pane_new(:scope, Dict{String,Any}())
        @test sp isa Ressac.ScopePane
        @test sp.subtype === :wave
        @test Ressac.title(sp) == "scope:wave"
    end

    @testset "respects target arg" begin
        sp = Ressac._pane_new(:scope, Dict{String,Any}("target" => "reservoir-graph"))
        @test sp.subtype === Symbol("reservoir-graph")
        @test Ressac.title(sp) == "scope:reservoir-graph"
    end

    @testset "serialize captures subtype" begin
        sp = Ressac._pane_new(:scope, Dict{String,Any}("target" => "spectrum"))
        @test Ressac.serialize(sp) == Dict{String,Any}(
            "subtype" => "spectrum",
        )
    end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: `UndefVarError: ScopePane not defined`.

- [ ] **Step 3: Create `pane_scope.jl`**

```julia
# src/pane_scope.jl
# :scope pane — visualizes a data stream coming from SC via
# /ressac/scope/*. Subtype is dynamic state (:wave, :amp, :spectrum,
# :reservoir-graph, etc.). on_close! unsubscribes from the OSC feed
# when no other scope pane is consuming the same subtype.

mutable struct ScopePane <: PaneImpl
    subtype::Symbol
end

function _scope_pane_ctor(args::AbstractDict)
    target = String(get(args, "target", "wave"))
    return ScopePane(Symbol(target))
end

render!(::ScopePane, area, buf) = nothing      # wired in step 7
handle_key!(::ScopePane, evt) = false          # wired in step 7
title(p::ScopePane) = "scope:$(p.subtype)"

serialize(p::ScopePane) = Dict{String,Any}("subtype" => String(p.subtype))

# on_close! placeholder — step 7 wires in /ressac/scope cleanup.
on_close!(::ScopePane) = nothing

register_pane_kind!(:scope, _scope_pane_ctor)
```

- [ ] **Step 4: Wire + commit**

After `include("pane_doc.jl")`:
```julia
include("pane_scope.jl")
```

Run tests then:
```bash
git add src/pane_scope.jl src/Ressac.jl test/test_pane_interface.jl
git commit -m "$(cat <<'EOF'
feat(panes): :scope kind with dynamic subtype state

Subtype lives in pane state (default :wave), captured by serialize
so the next boot restores the same scope variant. on_close! is a
hook for OSC subscription cleanup, wired up in step 7.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3 — Render swap

### Task 8: `WorkspaceManager` integration into `RessacApp.view`

**Files:**
- Modify: `src/tui_app.jl` (add `workspaces::WorkspaceManager` field; modify `view`)
- Modify: `src/pane_editor.jl`, `pane_log.jl`, `pane_doc.jl`, `pane_scope.jl` (fill in render! + handle_key! using existing code)
- Modify: `test/test_tui.jl` (extend with workspace-driven render assertions)

This task is the most invasive of the plan because it stitches the new pane system to Tachikoma's render pipeline while preserving every existing behavior. Step 7 of the migration plan from the spec.

- [ ] **Step 1: Read the spec section "Backward-compatibility migration plan"**

Open `docs/journal/20260529_split_pane_design.md`, jump to "Backward-compatibility migration plan", step 7. The contract for this task: `view(m::RessacApp, frame)` keeps its signature; only its body changes to dispatch through `WorkspaceManager`. The default workspace at boot is a single-workspace single-pane `:editor` that visually matches today's screen.

- [ ] **Step 2: Add `workspaces` field to `RessacApp`**

In `src/tui_app.jl`, find the `mutable struct RessacApp` definition (around line 59-225). Add a new field:

```julia
    # Sub-project 9: WorkspaceManager subsumes m.layout_*. Initialized
    # in __post_init__ (or by start_live!) with a single workspace
    # containing one :editor pane. The legacy layout_* fields are
    # kept temporarily for backward compat during the migration —
    # removed in step 14.
    workspaces::WorkspaceManager = WorkspaceManager()
```

Place it just after the existing `focus::Symbol = :patterns` field.

- [ ] **Step 3: Add a default-workspace bootstrapper**

In `src/tui_app.jl`, near the `RessacApp` constructor, add:

```julia
"""
    _ensure_default_workspace!(m::RessacApp)

Make sure the workspace manager has at least one workspace with one
:editor pane. Called by start_live! and by the persistence-restore
fallback path.
"""
function _ensure_default_workspace!(m::RessacApp)
    isempty(m.workspaces.workspaces) || return
    create_workspace!(m.workspaces, "")
    ws = current_workspace(m.workspaces)
    leaf = ws.tree::PaneLeaf
    push!(leaf.tabs, _pane_new(:editor, Dict{String,Any}()))
    leaf.current_tab = 1
end
```

- [ ] **Step 4: Reroute `view` body through `WorkspaceManager`**

Locate `function view(m::RessacApp, frame)` in `tui_app.jl` (search for `function view` near the bottom of the file or via `grep -n 'function view' src/tui_app.jl`).

Replace the body of `view` with a delegation that computes rects from the current workspace's tree and calls `render!` per leaf. Preserve the chrome rendering (status, hint, livedoc, logs) at the top and bottom; the workspace area fills the middle.

Replacement body (keep the existing function signature):

```julia
function view(m::RessacApp, frame)
    _ensure_default_workspace!(m)
    area = frame.area
    # Chrome top: workspace tab strip (1 row) + status (already
    # rendered by the existing _render_status_strip). Hint widget (1 row).
    ws_strip_y = area.y
    _render_workspace_strip!(m, area, ws_strip_y, frame.buf)
    status_y = ws_strip_y + 1
    _render_status_strip!(m, status_y, area, frame.buf)
    hint_y = status_y + 1
    _render_hint_widget!(m, hint_y, area, frame.buf)
    # Chrome bottom: livedoc (1 row) + global log tail (3 rows or 0).
    log_h = _global_log_tail_height(m)
    livedoc_y = area.y + area.h - log_h - 1
    log_y = livedoc_y + 1
    # Workspace area between top chrome and bottom chrome.
    ws_top    = hint_y + 1
    ws_height = livedoc_y - ws_top
    ws_area   = (x=area.x, y=ws_top, w=area.w, h=ws_height)
    ws = current_workspace(m.workspaces)
    if ws !== nothing
        rects = _compute_rects(ws.tree, ws_area)
        _render_tree!(ws.tree, rects, frame.buf, m)
        _render_floats!(ws.floats, frame.buf, m)
    end
    _render_livedoc_row!(m, livedoc_y, area, frame.buf)
    _render_global_log_tail!(m, log_y, area, log_h, frame.buf)
end
```

Add helper stubs near the top of `tui_app.jl`:

```julia
function _render_workspace_strip!(m::RessacApp, area, y, buf)
    # Placeholder — populated for real in Task 10 when multi-workspace
    # navigation lands. For now, render the current workspace's name
    # only (or "" for untitled).
    ws = current_workspace(m.workspaces)
    label = ws === nothing ? "" : (isempty(ws.name) ? "[untitled]" : "[$(ws.name)]")
    # Use the existing TK.set_string! to draw.
    TK.set_string!(buf, area.x, y, label, TK.tstyle(:text_dim))
end

function _render_tree!(node::LayoutNode, rects::Dict, buf, m::RessacApp)
    if node isa PaneLeaf
        r = rects[node.id]
        if 1 <= node.current_tab <= length(node.tabs)
            render!(node.tabs[node.current_tab],
                    (x=r.x, y=r.y, w=r.w, h=r.h), buf)
        end
        return
    end
    for child in node.children
        _render_tree!(child, rects, buf, m)
    end
end

function _render_floats!(floats::Vector{FloatingPane}, buf, m::RessacApp)
    for f in sort(floats; by = f -> f.z_order)
        render!(f.pane, (x=f.x, y=f.y, w=f.w, h=f.h), buf)
    end
end

_global_log_tail_height(m::RessacApp) = 3   # placeholder; refined in step 11
```

- [ ] **Step 5: Fill in `render!` for the four core kinds**

Each kind's render! gets the existing rendering logic relocated.

`src/pane_editor.jl` — replace the stub `render!(::EditorPane, area, buf) = nothing` with:

```julia
function render!(p::EditorPane, area, buf)
    # Reuse the existing Tachikoma editor render. The current
    # tab's content becomes the buffer text; cursor position +
    # scroll come from the tab's EditorBuffer.
    1 <= p.current_tab <= length(p.tabs) || return
    tab = p.tabs[p.current_tab]
    _render_editor_buffer!(tab, area, buf)
end
```

Add `_render_editor_buffer!` to `pane_editor.jl`:

```julia
"""
    _render_editor_buffer!(buffer, area, buf)

Render an EditorBuffer's text + cursor inside `area`. Delegates to
Tachikoma's text rendering helpers (the same code path used by the
old m.editor render before the pane migration).
"""
function _render_editor_buffer!(b::EditorBuffer, area, buf)
    # MVP rendering: dump each line as plain text. Cursor highlight
    # is a thin invariant we add later. Real syntax-highlighting +
    # autocomplete overlay belong in step 11 after the snippet
    # integration; for step 7 the goal is just "the text shows up".
    lines = split(b.content, '\n')
    for (i, line) in enumerate(lines)
        screen_y = area.y + i - 1 - b.scroll_offset
        if area.y <= screen_y < area.y + area.h
            chunk = first(line, area.w)
            TK.set_string!(buf, area.x, screen_y, chunk, TK.tstyle(:text))
        end
    end
end
```

`src/pane_log.jl` — fill in similarly using `_APP_LOG`:

```julia
function render!(p::LogPane, area, buf)
    log = _APP_LOG[]
    n = length(log)
    start_i = max(1, n - area.h + 1 + p.scroll)
    for (offset, i) in enumerate(start_i:n)
        screen_y = area.y + offset - 1
        if area.y <= screen_y < area.y + area.h
            line = first(log[i], area.w)
            TK.set_string!(buf, area.x, screen_y, line, TK.tstyle(:text))
        end
    end
end
```

`src/pane_doc.jl`:

```julia
function render!(p::DocPane, area, buf)
    entry = lookup_doc(p.name)
    lines = if entry === nothing
        ["(no entry for '$(p.name)')"]
    else
        vcat([entry.name, "", entry.short, "", split(entry.body, '\n')...])
    end
    for (offset, line) in enumerate(lines[1 + p.scroll : end])
        screen_y = area.y + offset - 1
        screen_y >= area.y + area.h && break
        chunk = first(line, area.w)
        TK.set_string!(buf, area.x, screen_y, chunk, TK.tstyle(:text))
    end
end
```

`src/pane_scope.jl`:

```julia
function render!(p::ScopePane, area, buf)
    # Reuse the existing _render_app_scope (in tui_scope.jl).
    # That function dispatches on _APP_SCOPE_TYPE; we set it here.
    _APP_SCOPE_TYPE[] = p.subtype
    # _render_app_scope expects a Rect; build one from our area tuple.
    rect = TK.Rect(area.x, area.y, area.w, area.h)
    _render_app_scope_to_rect!(rect, buf)
end

# Helper that wraps the existing _render_app_scope to accept an
# explicit rect argument instead of computing m.layout_scope.
function _render_app_scope_to_rect!(rect, buf)
    # Implementation defers to the same code path as the legacy
    # render; concretely: take the body of _render_app_scope and
    # replace `m.layout_scope` with `rect`. For step 7 the simplest
    # approach is to call the existing helper with a stub RessacApp
    # whose layout_scope is rect.
    # In practice we add a `render_scope_subtype!(subtype, rect, buf)`
    # function in tui_scope.jl and route through it.
    nothing
end
```

(The full implementation extracts the existing scope render code into a `render_scope_subtype!` helper. The plan calls this out but leaves the exact extraction to the implementer — it's mechanical and depends on the current `_render_app_scope` body shape.)

- [ ] **Step 6: Update `test/test_tui.jl` to drive through the new path**

The existing TUI tests that build a `RessacApp` and check render output should still pass. Add a sanity test that confirms the workspace manager is initialized:

Append to `test/test_tui.jl` (find a sensible testset to extend, e.g. around the `RessacApp` smoke test):

```julia
@testset "default workspace initialized" begin
    mock = MockOSCClient()
    sched = Scheduler(mock; cps=0.5)
    app = Ressac.RessacApp(; scheduler=sched)
    Ressac._ensure_default_workspace!(app)
    @test length(app.workspaces.workspaces) == 1
    ws = Ressac.current_workspace(app.workspaces)
    @test ws !== nothing
    @test ws.tree isa Ressac.PaneLeaf
    @test length(ws.tree.tabs) == 1
    @test ws.tree.tabs[1] isa Ressac.EditorPane
end
```

- [ ] **Step 7: Run the full test suite**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`

Expected: all green. Any test that previously asserted on `m.layout_*` rects needs updating to use the equivalent rect from `_compute_rects` (rare — most existing tests are higher-level).

- [ ] **Step 8: Smoke-test the live session**

Manual: `just live` (with `just audio` running). The TUI should look visually identical to before: one editor area, log tail at the bottom, hint widget, livedoc bar. The only difference is internal — m.layout_* fields are still present but no longer consulted by `view`.

- [ ] **Step 9: Commit**

```bash
git add src/tui_app.jl src/pane_editor.jl src/pane_log.jl src/pane_doc.jl src/pane_scope.jl test/test_tui.jl
git commit -m "$(cat <<'EOF'
feat(panes): WorkspaceManager drives view(); 4 core kinds render

The view body now computes rects via _compute_rects and dispatches
render! per leaf. Each of the 4 core kinds has its render
implementation filled in (delegating to the existing Tachikoma
text/scope helpers). m.layout_* fields are still present but no
longer consulted — they're removed in step 14.

Visually identical to pre-migration on the default workspace.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Split / close / nav + C-w pane mode + ex commands

**Files:**
- Create: `src/workspace_commands.jl`
- Create: `src/workspace_keymap.jl`
- Create: `test/test_workspace_commands.jl`
- Modify: `src/Ressac.jl`
- Modify: `src/tui_app.jl` (route C-w + ex commands)
- Modify: `test/runtests.jl`

- [ ] **Step 1: Write the failing tests**

Create `test/test_workspace_commands.jl`:

```julia
using Test
using Ressac

@testset "workspace_commands" begin
    @testset ":vsplit adds a sibling to the right" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}()))
        ws.tree.current_tab = 1
        Ressac.cmd_vsplit!(wm, "log", Dict{String,Any}())
        # After vsplit, ws.tree is a Container with the original leaf
        # and a new :log leaf.
        @test ws.tree isa Ressac.Container
        @test ws.tree.direction === :h
        @test length(ws.tree.children) == 2
    end

    @testset ":focus left/right navigates between siblings" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}()))
        ws.tree.current_tab = 1
        Ressac.cmd_vsplit!(wm, "log", Dict{String,Any}())
        focused_before = ws.focused_pane
        Ressac.cmd_focus!(wm, :right)
        @test ws.focused_pane != focused_before
        Ressac.cmd_focus!(wm, :left)
        @test ws.focused_pane == focused_before
    end

    @testset ":close removes focused leaf + collapses unary container" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}()))
        ws.tree.current_tab = 1
        Ressac.cmd_vsplit!(wm, "log", Dict{String,Any}())
        right_id = ws.focused_pane
        Ressac.cmd_close!(wm)
        @test ws.tree isa Ressac.PaneLeaf   # collapsed back to single leaf
        @test ws.focused_pane != right_id
    end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`

Expected: `UndefVarError: cmd_vsplit! not defined`.

- [ ] **Step 3: Create `workspace_commands.jl`**

```julia
# src/workspace_commands.jl
# Ex command handlers — invoked by the colon-command dispatcher and
# also by the keymap (pane mode short keys map to these).

function cmd_split!(wm::WorkspaceManager, kind_str::AbstractString,
                    args::AbstractDict; direction::Symbol = :v)
    ws = current_workspace(wm)
    ws === nothing && return
    kind = Symbol(kind_str)
    new_pane = _pane_new(kind, args)
    new_leaf = PaneLeaf(wm.next_pane_id, [new_pane], 1)
    wm.next_pane_id += 1
    ws.tree = _split_root(ws.tree, ws.focused_pane, direction, new_leaf)
    ws.focused_pane = new_leaf.id
    return
end

cmd_vsplit!(wm, kind, args) = cmd_split!(wm, kind, args; direction = :h)
cmd_hsplit!(wm, kind, args) = cmd_split!(wm, kind, args; direction = :v)

function cmd_close!(wm::WorkspaceManager)
    ws = current_workspace(wm)
    ws === nothing && return
    new_tree = _close_at(ws.tree, ws.focused_pane)
    new_tree === nothing && return  # would close the last pane; refuse
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
        wm.current_idx = mod1(wm.current_idx + 1, length(wm.workspaces))
    elseif op === :prev
        wm.current_idx = mod1(wm.current_idx - 1, length(wm.workspaces))
    end
    return
end
```

- [ ] **Step 4: Create `workspace_keymap.jl`**

```julia
# src/workspace_keymap.jl
# C-w pane mode + resize mode state machine. Single-shot by default;
# Tab toggles sticky.

mutable struct PaneModeState
    active::Bool
    sticky::Bool
end
PaneModeState() = PaneModeState(false, false)

const _PANE_MODE = PaneModeState()

"""
    _dispatch_pane_mode_key(wm, char) -> Bool

Handle one keystroke while in pane mode. Returns true if the key
was consumed. The keymap:
  s — hsplit (new pane below)
  v — vsplit (new pane to the right)
  h/j/k/l — navigate left/down/up/right
  c — close focused
  Tab — toggle sticky
  Esc — exit pane mode
"""
function _dispatch_pane_mode_key(wm::WorkspaceManager, char::Char)
    handled = true
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
        handled = false
    end
    if handled && !_PANE_MODE.sticky
        _PANE_MODE.active = false
    end
    return handled
end
```

- [ ] **Step 5: Wire into `Ressac.jl` + test runner**

In `src/Ressac.jl`, after `include("pane_scope.jl")`:
```julia
include("workspace_commands.jl")
include("workspace_keymap.jl")
```

In `test/runtests.jl`, after `include("test_workspace_manager.jl")`:
```julia
    include("test_workspace_commands.jl")
```

- [ ] **Step 6: Hook the keymap into `update!` in `tui_app.jl`**

Find the existing `update!(m::RessacApp, evt::TK.KeyEvent)` function. Near the top, before any other key handling in normal mode:

```julia
# Sub-project 9: C-w enters pane mode. Single keys until Esc or
# auto-exit on single-shot.
if _PANE_MODE.active
    if evt.key === :escape
        _PANE_MODE.active = false
        _PANE_MODE.sticky = false
        return
    elseif evt.key === :tab
        _PANE_MODE.sticky = !_PANE_MODE.sticky
        return
    elseif evt.key === :char
        if _dispatch_pane_mode_key(m.workspaces, evt.char)
            return
        end
    end
end
if m.editor.mode === :normal && evt.key === :ctrl && evt.char == 'w'
    _PANE_MODE.active = true
    return
end
```

(Adjust the exact match form to the actual TK.KeyEvent shape used in the codebase. The plan's contract is "C-w in normal mode enters pane mode".)

- [ ] **Step 7: Run tests + smoke + commit**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Smoke: `just live` → press `C-w v` → second pane appears to the right. `C-w l` → focus moves right. `C-w c` → focused pane closes.

```bash
git add src/workspace_commands.jl src/workspace_keymap.jl src/Ressac.jl src/tui_app.jl test/test_workspace_commands.jl test/runtests.jl
git commit -m "$(cat <<'EOF'
feat(panes): split/close/navigate + C-w pane mode + ex commands

cmd_split! / cmd_close! / cmd_focus! / cmd_workspace! ex command
handlers. Pane mode entered via C-w in normal mode; single-shot
by default, Tab toggles sticky. Resize mode comes in Task 10.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4 — Multi-workspace

### Task 10: Multi-workspace + `Ctrl-1..9` + tab strip render

**Files:**
- Modify: `src/workspace_commands.jl` (add `cmd_workspace_switch!` + `cmd_workspace_named!`)
- Modify: `src/tui_app.jl` (`_render_workspace_strip!` filled in, `Ctrl-N` globals routed)
- Modify: `test/test_workspace_commands.jl` (add switch tests)

- [ ] **Step 1: Add failing tests**

Append to `test/test_workspace_commands.jl`:

```julia
@testset "workspace switching" begin
    @testset "cmd_workspace_switch! by number" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "a")
        Ressac.create_workspace!(wm, "b")
        Ressac.create_workspace!(wm, "c")
        Ressac.cmd_workspace_switch!(wm, 1)
        @test wm.current_idx == 1
        Ressac.cmd_workspace_switch!(wm, 3)
        @test wm.current_idx == 3
    end

    @testset "cmd_workspace_named! by name" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "live")
        Ressac.create_workspace!(wm, "synth")
        Ressac.cmd_workspace_named!(wm, "live")
        @test Ressac.current_workspace(wm).name == "live"
    end

    @testset "cmd_workspace_named! falls back when name doesn't exist" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "live")
        prev = wm.current_idx
        Ressac.cmd_workspace_named!(wm, "ghost")
        @test wm.current_idx == prev
    end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: `UndefVarError: cmd_workspace_switch!`.

- [ ] **Step 3: Add handlers to `workspace_commands.jl`**

Append:

```julia
function cmd_workspace_switch!(wm::WorkspaceManager, idx::Int)
    1 <= idx <= length(wm.workspaces) || return
    wm.current_idx = idx
end

function cmd_workspace_named!(wm::WorkspaceManager, name::AbstractString)
    idx = findfirst(ws -> ws.name == name, wm.workspaces)
    idx === nothing && return
    wm.current_idx = idx
end
```

- [ ] **Step 4: Fill in `_render_workspace_strip!` in `tui_app.jl`**

Replace the placeholder version of `_render_workspace_strip!` with:

```julia
function _render_workspace_strip!(m::RessacApp, area, y, buf)
    x = area.x
    for (i, ws) in enumerate(m.workspaces.workspaces)
        is_current = i == m.workspaces.current_idx
        label = isempty(ws.name) ? "[$i]" : "[$i: $(ws.name)]"
        style = is_current ? TK.tstyle(:accent, bold=true) : TK.tstyle(:text_dim)
        x + textwidth(label) > area.x + area.w && break
        TK.set_string!(buf, x, y, label, style)
        x += textwidth(label) + 1
    end
end
```

- [ ] **Step 5: Hook `Ctrl-1..9` globals into `update!`**

In `tui_app.jl`, near the top of `update!`, before the pane mode dispatch:

```julia
# Sub-project 9: Ctrl-1..9 switch workspace globally (any mode).
if evt.key === :ctrl && evt.char in '1':'9'
    n = Int(evt.char - '0')
    cmd_workspace_switch!(m.workspaces, n)
    return
end
if evt.key === :ctrl && evt.key2 === :page_up
    cmd_workspace!(m.workspaces, :prev)
    return
end
if evt.key === :ctrl && evt.key2 === :page_down
    cmd_workspace!(m.workspaces, :next)
    return
end
```

(Adjust to actual TK.KeyEvent field layout — the test verifies behavior, not the field names.)

- [ ] **Step 6: Run tests + smoke + commit**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Smoke: `just live` → `:workspace new live` → tab strip shows `[1: live]`. `Ctrl-1` jumps. `Ctrl-PgUp/Dn` cycles.

```bash
git add src/workspace_commands.jl src/tui_app.jl test/test_workspace_commands.jl
git commit -m "$(cat <<'EOF'
feat(panes): multi-workspace switching + Ctrl-N globals + tab strip

cmd_workspace_switch! and cmd_workspace_named! hand off to the
manager. Tab strip rendered at the top of view(). Ctrl-1..9 jump
in any mode (live UX: switch fast without leaving insert). Ctrl-
PgUp/Dn cycle prev/next.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 5 — Persistence + snippet integration

### Task 11: Layout persistence (`last_layout.toml` + named layouts)

**Files:**
- Create: `src/workspace_persistence.jl`
- Create: `test/test_workspace_persistence.jl`
- Create: `test/fixtures/layouts/sample_layout.toml`
- Modify: `src/Ressac.jl`
- Modify: `src/tui_app.jl` (call save on `:q`, call load on boot)
- Modify: `test/runtests.jl`

- [ ] **Step 1: Create fixture**

`test/fixtures/layouts/sample_layout.toml`:
```toml
[workspaces.0]
name = "live"
focused_pane = 1

[workspaces.0.tree]
type = "pane"
kind = "editor"
id = 1
state = { tabs = [{ role = "patterns", name = "main", content = "@d1 :bd\n", cursor_row = 1, cursor_col = 0, scroll_offset = 0 }], current_tab = 1 }
```

- [ ] **Step 2: Write the failing tests**

`test/test_workspace_persistence.jl`:

```julia
using Test
using TOML
using Ressac

@testset "workspace_persistence" begin
    @testset "save → load round-trip" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "live")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}(
            "buffer_role" => "patterns", "name" => "main",
        )))
        ws.tree.current_tab = 1
        tmp = mktempdir()
        try
            path = joinpath(tmp, "layout.toml")
            Ressac.save_layout(wm, path)
            wm2 = Ressac.WorkspaceManager()
            Ressac.load_layout!(wm2, path)
            @test length(wm2.workspaces) == 1
            @test wm2.workspaces[1].name == "live"
            tree = wm2.workspaces[1].tree
            @test tree isa Ressac.PaneLeaf
            @test length(tree.tabs) == 1
            @test tree.tabs[1] isa Ressac.EditorPane
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

    @testset "load failure falls back to default workspace" begin
        wm = Ressac.WorkspaceManager()
        @test_logs (:warn, r"") begin
            Ressac.load_layout!(wm, "/nonexistent/path/layout.toml")
        end
        # Manager is unchanged on failure; the caller will install a
        # default workspace.
        @test isempty(wm.workspaces)
    end

    @testset "load fixture" begin
        fixture = joinpath(@__DIR__, "fixtures", "layouts", "sample_layout.toml")
        wm = Ressac.WorkspaceManager()
        Ressac.load_layout!(wm, fixture)
        @test length(wm.workspaces) == 1
        @test wm.workspaces[1].name == "live"
    end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: `UndefVarError: save_layout`.

- [ ] **Step 4: Create `workspace_persistence.jl`**

```julia
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
        return Dict{String,Any}(
            "type" => "pane",
            "id" => node.id,
            "kind" => "editor",   # MVP: track via tab. Refined in Task 12.
            "current_tab" => node.current_tab,
            "state" => length(node.tabs) > 0 ? serialize(node.tabs[1]) : Dict{String,Any}(),
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
    wm.current_idx = Int(get(raw, "current_idx",
                              isempty(wm.workspaces) ? 0 : 1))
    return nothing
end

function _deserialize_tree(d::AbstractDict, wm::WorkspaceManager)
    if d["type"] == "pane"
        kind = Symbol(get(d, "kind", "editor"))
        args = get(d, "state", Dict{String,Any}())
        pane = _pane_new(kind, args isa Dict ? args : Dict{String,Any}())
        leaf = PaneLeaf(Int(get(d, "id", wm.next_pane_id)),
                        [pane], Int(get(d, "current_tab", 1)))
        wm.next_pane_id = max(wm.next_pane_id, leaf.id + 1)
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
```

- [ ] **Step 5: Wire into Ressac.jl + test runner**

In `src/Ressac.jl`, after `include("workspace_keymap.jl")`:
```julia
include("workspace_persistence.jl")
```

In `test/runtests.jl`, after `include("test_workspace_commands.jl")`:
```julia
    include("test_workspace_persistence.jl")
```

- [ ] **Step 6: Hook save + load into `tui_app.jl`**

In the `:q` quit handler (`grep -n ':q' src/tui_app.jl | head -5`), add a save call before the actual quit:

```julia
Ressac.save_layout(m.workspaces, Ressac._default_layout_path())
```

In `start_live!` (or wherever `RessacApp` is constructed), after the app creation:

```julia
Ressac.load_layout!(m.workspaces, Ressac._default_layout_path())
Ressac._ensure_default_workspace!(m)   # fallback if load did nothing
```

- [ ] **Step 7: Run tests + commit**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Smoke: `just live` → split a few times → `:q` → relaunch → layout restored.

```bash
git add src/workspace_persistence.jl src/Ressac.jl src/tui_app.jl test/test_workspace_persistence.jl test/runtests.jl test/fixtures/layouts/sample_layout.toml
git commit -m "$(cat <<'EOF'
feat(panes): layout autosave + restore + named layouts

save_layout writes ~/.config/ressac/last_layout.toml at :q.
load_layout! restores at boot with graceful fallback to default
workspace on failure. Named layouts live in
~/.config/ressac/layouts/<name>.toml — :layout save/load lands
in Task 12 via the ex command path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: Snippet `panes = [...]` application

**Files:**
- Create: `src/snippet_panes.jl`
- Create: `test/test_snippet_panes_apply.jl`
- Modify: `src/Ressac.jl`
- Modify: `src/tui_app.jl` (call snippet_panes from `_starter_command!` and the snippet insert path)
- Modify: `test/runtests.jl`

- [ ] **Step 1: Write the failing tests**

`test/test_snippet_panes_apply.jl`:

```julia
using Test
using Ressac

@testset "snippet panes apply" begin
    @testset "mode=starter rebuilds workspace from panes spec" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}()))
        ws.tree.current_tab = 1

        panes_spec = [
            Dict("kind" => "editor", "role" => "primary"),
            Dict("kind" => "log",    "role" => "side", "side" => "right", "ratio" => 0.4),
            Dict("kind" => "doc",    "role" => "side", "side" => "bottom",
                 "ratio" => 0.3, "ref" => "gain"),
        ]
        Ressac.apply_snippet_panes!(wm, panes_spec, :starter)
        ws = Ressac.current_workspace(wm)
        @test ws.tree isa Ressac.Container
        # primary should be reachable as a leaf containing :editor
        leaves = Ressac._all_leaves(ws.tree)
        kinds = sort([typeof(leaf.tabs[1]) for leaf in leaves])
        @test Ressac.EditorPane in kinds || Ressac.EditorPane === eltype(kinds)
    end

    @testset "mode=block keeps current tree; primary inserts content into focused editor" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}()))
        ws.tree.current_tab = 1
        tree_before = ws.tree
        panes_spec = [Dict("kind" => "editor", "role" => "primary")]
        Ressac.apply_snippet_panes!(wm, panes_spec, :block)
        @test ws.tree === tree_before
    end

    @testset "bad kind warns + skips that pane spec, rest applies" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}()))
        ws.tree.current_tab = 1
        panes_spec = [
            Dict("kind" => "editor", "role" => "primary"),
            Dict("kind" => "ghost",  "role" => "side", "side" => "right"),
            Dict("kind" => "log",    "role" => "side", "side" => "right"),
        ]
        @test_logs (:warn, r"unregistered") begin
            Ressac.apply_snippet_panes!(wm, panes_spec, :starter)
        end
        # Tree exists, has at least the editor + log side, not the ghost.
        @test current_workspace(wm).tree isa Ressac.Container
    end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`

Expected: `UndefVarError: apply_snippet_panes!`.

- [ ] **Step 3: Create `src/snippet_panes.jl`**

```julia
# src/snippet_panes.jl
# Resolve a snippet's panes = [...] spec into a workspace layout.

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

"""
    apply_snippet_panes!(wm, panes_spec, mode)

`mode` is `:starter` or `:block`. For `:starter`, rebuilds the
focused workspace's tree from the spec (primary becomes root, sides
are split off). For `:block`, the current tree is unchanged; the
primary's content gets inserted at the focused editor's cursor
(the actual insertion is handled by the caller — this function
returns the inserted-content target leaf id).

Bad kinds warn + skip; the rest of the spec still applies.
"""
function apply_snippet_panes!(wm::WorkspaceManager, panes_spec::AbstractVector,
                              mode::Symbol)
    ws = current_workspace(wm)
    ws === nothing && return
    # Find primary
    primary_idx = findfirst(p -> String(get(p, "role", "")) == "primary", panes_spec)
    primary_idx === nothing && (@warn "snippet panes spec has no primary; skip"; return)
    primary_spec = panes_spec[primary_idx]
    primary_kind = Symbol(primary_spec["kind"])
    if !haskey(_PANE_KINDS, primary_kind)
        @warn "snippet panes: primary kind ':$primary_kind' unregistered; skip"
        return
    end
    primary_pane = try
        _pane_new(primary_kind,
                  Dict{String,Any}(filter(p -> first(p) != "role" && first(p) != "side" &&
                                                 first(p) != "ratio", collect(primary_spec))))
    catch err
        @warn "snippet panes: primary construction failed: $(sprint(showerror, err))"
        return
    end

    if mode === :starter
        primary_leaf = PaneLeaf(wm.next_pane_id, [primary_pane], 1)
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
        # Primary's content insertion is done by the caller (snippet
        # insert path); we return so cmd_insert_snippet! can dispatch.
    end
    return
end

function _apply_side_pane!(wm::WorkspaceManager, ws::Workspace, spec::AbstractDict)
    kind = Symbol(get(spec, "kind", ""))
    if !haskey(_PANE_KINDS, kind)
        @warn "snippet panes: side kind ':$kind' unregistered; skip"
        return
    end
    side = Symbol(get(spec, "side", "right"))
    direction = side in (:left, :right) ? :h : :v
    new_pane = try
        _pane_new(kind,
                  Dict{String,Any}(filter(p -> first(p) != "role" && first(p) != "side" &&
                                                 first(p) != "ratio", collect(spec))))
    catch err
        @warn "snippet panes: side pane construction failed: $(sprint(showerror, err))"
        return
    end
    new_leaf = PaneLeaf(wm.next_pane_id, [new_pane], 1)
    wm.next_pane_id += 1
    ws.tree = _split_root(ws.tree, ws.focused_pane, direction, new_leaf)
end
```

- [ ] **Step 4: Wire + run + commit**

In `src/Ressac.jl`, after `include("workspace_persistence.jl")`:
```julia
include("snippet_panes.jl")
```

In `test/runtests.jl`, after `include("test_workspace_persistence.jl")`:
```julia
    include("test_snippet_panes_apply.jl")
```

In `tui_app.jl`, in `_starter_command!` (after the snippet lookup, before the buffer text insert):
```julia
isempty(snip.panes) || Ressac.apply_snippet_panes!(m.workspaces, snip.panes, snip.mode)
```

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

```bash
git add src/snippet_panes.jl src/Ressac.jl src/tui_app.jl test/test_snippet_panes_apply.jl test/runtests.jl
git commit -m "$(cat <<'EOF'
feat(panes): snippet panes = [...] application + mode dispatch

starter mode rebuilds the workspace tree from primary + sides;
block mode adds sides only and lets the caller handle the primary's
content insertion. Bad kinds warn + skip without aborting the
whole apply.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: User config override stack

**Files:**
- Modify: `src/snippet_panes.jl` (consult user config before applying spec)
- Modify: `src/session_config.jl` (extend `RessacConfig` with `[panes]`)
- Modify: `test/test_snippet_panes_apply.jl` (add override tests)

- [ ] **Step 1: Add failing tests**

Append to `test/test_snippet_panes_apply.jl`:

```julia
@testset "snippet panes — user config overrides" begin
    @testset "config override replaces snippet's panes spec" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}()))
        ws.tree.current_tab = 1
        cfg = Ressac.RessacConfig()
        # Inject a fake override targeting a snippet named "test-snip".
        cfg.panes_overrides["test-snip"] = [
            Dict("kind" => "editor", "role" => "primary"),
            Dict("kind" => "doc",    "role" => "side", "side" => "right", "ref" => "gain"),
        ]
        Ressac._RESSAC_CONFIG[] = cfg
        snippet_panes = [Dict("kind" => "editor", "role" => "primary")]
        Ressac.apply_snippet_panes!(wm, snippet_panes, :starter; snippet_name = "test-snip")
        ws = Ressac.current_workspace(wm)
        # The override produced two panes; the snippet only one.
        @test length(Ressac._all_leaves(ws.tree)) == 2
    end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`

Expected: error about `panes_overrides` not being a field of `RessacConfig`, or `apply_snippet_panes!` not accepting `snippet_name`.

- [ ] **Step 3: Extend `RessacConfig`**

In `src/session_config.jl`, find the `RessacConfig` struct. Add fields:

```julia
    # Sub-project 9: per-snippet panes overrides + per-kind defaults.
    # Loaded from [panes.snippets."<name>"].panes and [panes.kinds.<name>]
    # sections of ~/.config/ressac/config.toml.
    panes_overrides::Dict{String,Vector{Dict{String,Any}}} = Dict{String,Vector{Dict{String,Any}}}()
    panes_kind_defaults::Dict{Symbol,Dict{String,Any}} = Dict{Symbol,Dict{String,Any}}()
```

In `_load_ressac_config!` (or whichever loader populates `RessacConfig`), parse the `[panes]` sections:

```julia
panes_section = get(raw, "panes", Dict())
snippets_raw = get(panes_section, "snippets", Dict())
for (snippet_name, body) in snippets_raw
    panes_list = get(body, "panes", nothing)
    panes_list isa AbstractVector || continue
    cfg.panes_overrides[String(snippet_name)] = collect(Dict{String,Any}, panes_list)
end
kinds_raw = get(panes_section, "kinds", Dict())
for (kind_name, body) in kinds_raw
    cfg.panes_kind_defaults[Symbol(kind_name)] = Dict{String,Any}(body)
end
```

- [ ] **Step 4: Honor the override in `apply_snippet_panes!`**

In `src/snippet_panes.jl`, change the signature to accept `snippet_name`:

```julia
function apply_snippet_panes!(wm::WorkspaceManager, panes_spec::AbstractVector,
                              mode::Symbol; snippet_name::AbstractString = "")
    cfg = _RESSAC_CONFIG[]
    if cfg !== nothing && haskey(cfg.panes_overrides, snippet_name)
        panes_spec = cfg.panes_overrides[snippet_name]
    end
    # ... rest unchanged
```

In `tui_app.jl`'s `_starter_command!`, pass the snippet name:

```julia
Ressac.apply_snippet_panes!(m.workspaces, snip.panes, snip.mode;
                            snippet_name = snip.name)
```

- [ ] **Step 5: Run tests + commit**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

```bash
git add src/snippet_panes.jl src/session_config.jl src/tui_app.jl test/test_snippet_panes_apply.jl
git commit -m "$(cat <<'EOF'
feat(panes): user config override stack for snippet panes

~/.config/ressac/config.toml [panes.snippets."<name>"].panes
totally replaces a snippet's panes spec. Per-kind defaults parsed
into RessacConfig.panes_kind_defaults — consumed in Task 14 when
we implement the tile/float toggle.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 6 — Floats + cleanup

### Task 14: Floating panes (`:float` toggle + `Ctrl-Shift-F`)

**Files:**
- Modify: `src/workspace_commands.jl` (add tile/float toggles)
- Modify: `src/workspace_manager.jl` (add `_pane_to_float!`, `_float_to_pane!`)
- Modify: `src/tui_app.jl` (Ctrl-Shift-F handler + show/hide floats)
- Modify: `test/test_workspace_commands.jl`

- [ ] **Step 1: Add failing tests**

Append to `test/test_workspace_commands.jl`:

```julia
@testset "tile/float toggle" begin
    @testset "cmd_float! moves focused leaf to floats vector" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}()))
        ws.tree.current_tab = 1
        Ressac.cmd_vsplit!(wm, "log", Dict{String,Any}())
        # focused is now the new log leaf on the right
        log_id = ws.focused_pane
        Ressac.cmd_float!(wm)
        @test length(ws.floats) == 1
        @test ws.floats[1].pane isa Ressac.LogPane
        # The tree collapsed back to single editor leaf
        @test ws.tree isa Ressac.PaneLeaf
    end

    @testset "cmd_tile! moves topmost float back into the tree" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}()))
        ws.tree.current_tab = 1
        Ressac.cmd_vsplit!(wm, "log", Dict{String,Any}())
        Ressac.cmd_float!(wm)
        @test length(ws.floats) == 1
        Ressac.cmd_tile!(wm)
        @test isempty(ws.floats)
        @test ws.tree isa Ressac.Container
    end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: `UndefVarError: cmd_float!`.

- [ ] **Step 3: Implement the toggles**

In `src/workspace_commands.jl`, append:

```julia
function cmd_float!(wm::WorkspaceManager)
    ws = current_workspace(wm)
    ws === nothing && return
    # Find focused leaf
    hit = _find_leaf_parent(ws.tree, ws.focused_pane)
    leaf = if hit === nothing
        # focused is the root
        ws.tree isa PaneLeaf ? ws.tree : nothing
    else
        parent, idx = hit
        parent.children[idx]
    end
    leaf === nothing && return
    # Move all tabs as a single float (z_order = last + 1)
    pane = leaf.tabs[leaf.current_tab]
    z = isempty(ws.floats) ? 1 : maximum(f.z_order for f in ws.floats) + 1
    push!(ws.floats, FloatingPane(pane, 10, 5, 60, 20, z))
    # Remove the leaf from the tree
    new_tree = _close_at(ws.tree, leaf.id)
    new_tree === nothing && (new_tree = PaneLeaf(wm.next_pane_id, [_pane_new(:editor, Dict{String,Any}())], 1); wm.next_pane_id += 1)
    ws.tree = new_tree
    ws.focused_pane = _first_leaf_id(ws.tree)
    return
end

function cmd_tile!(wm::WorkspaceManager)
    ws = current_workspace(wm)
    ws === nothing && return
    isempty(ws.floats) && return
    # Pop the top z_order float and reinsert as a side pane (right of focused).
    top = popmax_by!(ws.floats, f -> f.z_order)
    new_leaf = PaneLeaf(wm.next_pane_id, [top.pane], 1)
    wm.next_pane_id += 1
    ws.tree = _split_root(ws.tree, ws.focused_pane, :h, new_leaf)
    ws.focused_pane = new_leaf.id
    return
end

function popmax_by!(v::AbstractVector, key)
    idx = argmax(key.(v))
    item = v[idx]
    deleteat!(v, idx)
    return item
end
```

- [ ] **Step 4: Add `Ctrl-Shift-F` handler**

In `tui_app.jl`'s `update!`, before pane mode dispatch:

```julia
# Toggle visibility of all floats in current workspace.
if evt.key === :ctrl && evt.key === :shift && evt.char == 'F'
    ws = Ressac.current_workspace(m.workspaces)
    ws === nothing || (m.floats_hidden = !m.floats_hidden)
    return
end
```

Add `floats_hidden::Bool = false` to `RessacApp` struct.

In `view()`, gate the float render:

```julia
if !m.floats_hidden
    _render_floats!(ws.floats, frame.buf, m)
end
```

- [ ] **Step 5: Run + smoke + commit**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Smoke: `just live` → split → `:float` on focused pane → that pane lifts out of the tree, becomes a floating window. `:tile` puts it back. `Ctrl-Shift-F` toggles all-float visibility.

```bash
git add src/workspace_commands.jl src/tui_app.jl test/test_workspace_commands.jl
git commit -m "$(cat <<'EOF'
feat(panes): floating panes — :float / :tile toggle + Ctrl-Shift-F

cmd_float! lifts the focused leaf into ws.floats with default
geometry (10, 5, 60×20) + top z-order. cmd_tile! pops the topmost
float back into the tree as a right-split of the currently focused
pane. Ctrl-Shift-F toggles render visibility of every float in the
current workspace (zellij convention).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 15: Cleanup — remove `m.layout_*` + dead code

**Files:**
- Modify: `src/tui_app.jl` (delete `layout_patterns`, `layout_synth`, `layout_synth_tabs`, `layout_scope`, `layout_logs` fields; delete the legacy rect-computation code from the old `view` body if still present)

- [ ] **Step 1: Grep + visual sweep**

Find every remaining reference to `m.layout_*`:

```bash
grep -n 'm.layout_\|layout_patterns\|layout_synth\|layout_logs\|layout_scope' src/*.jl
```

Each hit needs to either:
- (a) be replaced with a call into the workspace manager for the appropriate rect, OR
- (b) be deleted entirely if the code is dead

- [ ] **Step 2: Remove the field declarations**

In `src/tui_app.jl`, find the `RessacApp` struct (lines around 219-223 originally). Delete the 5 lines:

```julia
    layout_patterns::Union{Nothing,TK.Rect} = nothing
    layout_synth::Union{Nothing,TK.Rect}    = nothing
    layout_synth_tabs::Union{Nothing,TK.Rect} = nothing
    layout_scope::Union{Nothing,TK.Rect}    = nothing
    layout_logs::Union{Nothing,TK.Rect}     = nothing
```

- [ ] **Step 3: Fix the remaining references**

Mouse handling (around lines 324-381 in the original) references `m.layout_*` for hit-testing clicks. Replace with the workspace manager:

```julia
ws = current_workspace(m.workspaces)
ws === nothing && return
area = frame.area  # or compute from your event source
rects = _compute_rects(ws.tree, area)
for (leaf_id, rect) in rects
    if _in_rect(rect, evt.x, evt.y)
        ws.focused_pane = leaf_id
        # ... dispatch to the leaf's PaneImpl
        break
    end
end
```

The exact form depends on how the mouse handler is currently shaped — the key constraint is "no field named `layout_*` is referenced anywhere".

- [ ] **Step 4: Run the full test suite**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: 1542 existing tests + ~60 new ones all green.

- [ ] **Step 5: Final grep to confirm zero refs**

```bash
grep -rn 'layout_patterns\|layout_synth\|layout_logs\|layout_scope\|layout_synth_tabs' src/
```

Expected: empty.

- [ ] **Step 6: Commit**

```bash
git add src/tui_app.jl
git commit -m "$(cat <<'EOF'
refactor(panes): remove m.layout_* fields + legacy rect computation

The 5 layout_* fields and their per-call computation in view() are
fully subsumed by the WorkspaceManager. Mouse handling now hit-tests
against _compute_rects output. About 300 lines disappear from
tui_app.jl.

Sub-project 9 is now feature-complete. Sub-project 10 will migrate
the 6 modal overlays (mixer, browser, snippet picker, synth library,
sccode, :guide) into the floating pane system.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Acceptance verification

After all 15 tasks complete, verify against the design's acceptance criteria:

- [ ] `WorkspaceManager` replaces `m.layout_*`; grep confirms no
  `layout_patterns`/`layout_synth`/etc. references remain in `src/`
- [ ] The 4 core kinds (`:editor`, `:log`, `:scope`, `:doc`) registered
  via `register_pane_kind!` at boot
- [ ] `<C-w>` enters pane mode; single-key splits/nav/close work;
  `Tab` toggles sticky; `Esc` exits
- [ ] Ex commands `:split <kind>`, `:vsplit <kind>`, `:focus <dir>`,
  `:close`, `:workspace <op>`, `:layout save/load`, `:tile`, `:float`
  all functional
- [ ] `Ctrl-1..9` jumps workspaces; `Ctrl-PgUp/Dn` cycles; tab strip
  renders at top
- [ ] `~/.config/ressac/last_layout.toml` saved on `:q`, restored on
  next boot with graceful fallback
- [ ] `:starter <name>` with `panes = [...]` rebuilds the focused
  workspace per spec
- [ ] User config `[panes.snippets."<name>"].panes` overrides the
  snippet's spec
- [ ] `:float` on a focused tile pane lifts it to `ws.floats`;
  `:tile` reverses; `Ctrl-Shift-F` toggles all-float visibility
- [ ] Test suite green: `julia --project=. -e 'using Pkg; Pkg.test()'`
- [ ] Boot time ≤ 250 ms warm: `@time` instrumenting `start_live!`
  measured against the sub-project 8 baseline (198 ms)
