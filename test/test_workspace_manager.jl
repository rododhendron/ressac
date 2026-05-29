using Test
using Ressac

if !isdefined(Main, :_NullPane)
    struct _NullPane <: Ressac.PaneImpl end
    Ressac.render!(::_NullPane, ::Any, ::Any) = nothing
    Ressac.handle_key!(::_NullPane, ::Any) = false
    Ressac.title(::_NullPane) = "null"
end

@testset "workspace_manager — tree ops" begin
    @testset "PaneLeaf construction has one tab + current_tab=1" begin
        leaf = Ressac.PaneLeaf(1, Ressac.PaneImpl[_NullPane()], 1)
        @test leaf.id == 1
        @test length(leaf.tabs) == 1
        @test leaf.current_tab == 1
    end

    @testset "Container has direction + children + ratios" begin
        a = Ressac.PaneLeaf(1, Ressac.PaneImpl[_NullPane()], 1)
        b = Ressac.PaneLeaf(2, Ressac.PaneImpl[_NullPane()], 1)
        c = Ressac.Container(:h, Ressac.LayoutNode[a, b], [0.5, 0.5])
        @test c.direction === :h
        @test length(c.children) == 2
        @test c.ratios ≈ [0.5, 0.5]
    end

    @testset "_split_at! inserts sibling in matching-direction container" begin
        a = Ressac.PaneLeaf(1, Ressac.PaneImpl[_NullPane()], 1)
        b = Ressac.PaneLeaf(2, Ressac.PaneImpl[_NullPane()], 1)
        root = Ressac.Container(:h, Ressac.LayoutNode[a, b], [0.5, 0.5])
        new_leaf = Ressac.PaneLeaf(3, Ressac.PaneImpl[_NullPane()], 1)
        Ressac._split_at!(root, 1, :h, new_leaf)
        @test length(root.children) == 3
        @test root.children[2] === new_leaf
        @test root.ratios ≈ [0.333, 0.333, 0.333] atol=0.01
    end

    @testset "_split_root wraps standalone leaf when direction differs" begin
        a = Ressac.PaneLeaf(1, Ressac.PaneImpl[_NullPane()], 1)
        new_leaf = Ressac.PaneLeaf(2, Ressac.PaneImpl[_NullPane()], 1)
        new_root = Ressac._split_root(a, 1, :v, new_leaf)
        @test new_root isa Ressac.Container
        @test new_root.direction === :v
        @test length(new_root.children) == 2
        @test new_root.children[1] === a
        @test new_root.children[2] === new_leaf
    end

    @testset "_close_at removes leaf + collapses unary container" begin
        a = Ressac.PaneLeaf(1, Ressac.PaneImpl[_NullPane()], 1)
        b = Ressac.PaneLeaf(2, Ressac.PaneImpl[_NullPane()], 1)
        root = Ressac.Container(:h, Ressac.LayoutNode[a, b], [0.5, 0.5])
        new_root = Ressac._close_at(root, 2)
        @test new_root === a
    end

    @testset "_navigate :right within a horizontal container" begin
        a = Ressac.PaneLeaf(1, Ressac.PaneImpl[_NullPane()], 1)
        b = Ressac.PaneLeaf(2, Ressac.PaneImpl[_NullPane()], 1)
        root = Ressac.Container(:h, Ressac.LayoutNode[a, b], [0.5, 0.5])
        @test Ressac._navigate(root, 1, :right) == 2
        @test Ressac._navigate(root, 2, :right) === nothing
    end

    @testset "_compute_rects partitions area by ratios" begin
        a = Ressac.PaneLeaf(1, Ressac.PaneImpl[_NullPane()], 1)
        b = Ressac.PaneLeaf(2, Ressac.PaneImpl[_NullPane()], 1)
        root = Ressac.Container(:h, Ressac.LayoutNode[a, b], [0.6, 0.4])
        area = (x=0, y=0, w=100, h=20)
        rects = Ressac._compute_rects(root, area)
        @test rects[1] == (x=0,  y=0, w=60, h=20)
        @test rects[2] == (x=60, y=0, w=40, h=20)
    end
end
