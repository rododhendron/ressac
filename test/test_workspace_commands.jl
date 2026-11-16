include(joinpath(@__DIR__, "helpers.jl"))
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
        focused_after_split = ws.focused_pane
        # After vsplit, focus moves to the new pane (right side).
        Ressac.cmd_focus!(wm, :left)
        @test ws.focused_pane != focused_after_split
        Ressac.cmd_focus!(wm, :right)
        @test ws.focused_pane == focused_after_split
    end

    @testset ":close removes focused leaf + collapses unary container" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}()))
        ws.tree.current_tab = 1
        Ressac.cmd_vsplit!(wm, "log", Dict{String,Any}())
        Ressac.cmd_close!(wm)
        @test ws.tree isa Ressac.PaneLeaf   # collapsed back to single leaf
    end

    @testset ":close refuses to close the last pane" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}()))
        ws.tree.current_tab = 1
        tree_before = ws.tree
        Ressac.cmd_close!(wm)
        @test ws.tree === tree_before
    end

    @testset "cmd_hsplit! creates a vertical container" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}()))
        ws.tree.current_tab = 1
        Ressac.cmd_hsplit!(wm, "log", Dict{String,Any}())
        @test ws.tree isa Ressac.Container
        @test ws.tree.direction === :v
    end
end

@testset "mode pane — ses touches sont celles du registre" begin
    # Une app, Ctrl-w, puis les touches : ce que le scope :pane_mode déclare
    # est ce qui s'exécute.
    function pm_app()
        app, frame = _new_app()
        Ressac._active_editor(app).mode = :normal
        _key!(app, :ctrl, 'w')
        @assert Ressac._PANE_MODE.active
        return app, Ressac.current_workspace(app.workspaces)
    end
    leaves(ws) = length(Ressac._all_leaves(ws.tree))

    @testset "une opération laisse le mode actif, pour enchaîner" begin
        app, ws = pm_app()
        _key!(app, 'v')
        @test ws.tree isa Ressac.Container && ws.tree.direction === :h && leaves(ws) == 2
        @test Ressac._PANE_MODE.active
        right = ws.focused_pane
        _key!(app, 'h')
        @test ws.focused_pane != right && Ressac._PANE_MODE.active
        _key!(app, :right)                                  # les flèches aussi
        @test ws.focused_pane == right
        _key!(app, 's')
        @test leaves(ws) == 3
        _key!(app, 'c')
        @test leaves(ws) == 2
        _key!(app, '<')
        @test ws.tree.ratios[1] != 0.5
        _key!(app, '=')
        @test ws.tree.ratios ≈ [0.5, 0.5]
        _key!(app, 'r')
        @test ws.tree.direction === :v
        _key!(app, 'z')
        @test app.zoom_leaf == ws.focused_pane
        Ressac._PANE_MODE.active = false
    end

    @testset "une touche inconnue est avalée, sans sortir ni toucher au texte" begin
        app, ws = pm_app()
        before = _buffer_text(app)
        _key!(app, 'x'); _key!(app, 'q')
        @test Ressac._PANE_MODE.active && _buffer_text(app) == before && leaves(ws) == 1
        Ressac._PANE_MODE.active = false
    end

    @testset "Échap, Entrée et Ctrl-w sortent" begin
        for exit! in (a -> _key!(a, :escape), a -> _key!(a, :enter), a -> _key!(a, :ctrl, 'w'))
            app, ws = pm_app()
            exit!(app)
            @test !Ressac._PANE_MODE.active
        end
    end

    @testset "chaque touche déclarée a une action" begin
        @test all(b -> b.action !== nothing, Ressac.bindings(:pane_mode))
        @test all(b -> b.action !== nothing, Ressac.bindings(:tap))
        @test all(b -> b.action !== nothing, Ressac.bindings(:piano))
        @test all(b -> b.action !== nothing, Ressac.bindings(:visual))
        # tout ce que `_PIANO_KEYMAP` connaît est une touche du piano
        declared = Set(k for b in Ressac.bindings(:piano) for k in b.keys)
        @test all(c -> string(c) in declared, keys(Ressac._PIANO_KEYMAP))
    end
end

@testset "workspace switching commands" begin
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

    @testset "cmd_workspace_switch! ignores out-of-range index" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "a")
        Ressac.cmd_workspace_switch!(wm, 99)
        @test wm.current_idx == 1   # unchanged
        Ressac.cmd_workspace_switch!(wm, 0)
        @test wm.current_idx == 1
    end

    @testset "cmd_workspace_named! by name" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "live")
        Ressac.create_workspace!(wm, "synth")
        Ressac.cmd_workspace_named!(wm, "live")
        @test Ressac.current_workspace(wm).name == "live"
    end

    @testset "cmd_workspace_named! noop when name doesn't exist" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "live")
        prev = wm.current_idx
        Ressac.cmd_workspace_named!(wm, "ghost")
        @test wm.current_idx == prev
    end

    @testset "cmd_workspace! :next/:prev cycles" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "a")
        Ressac.create_workspace!(wm, "b")
        Ressac.create_workspace!(wm, "c")
        Ressac.cmd_workspace_switch!(wm, 1)
        Ressac.cmd_workspace!(wm, :next)
        @test wm.current_idx == 2
        Ressac.cmd_workspace!(wm, :next)
        @test wm.current_idx == 3
        Ressac.cmd_workspace!(wm, :next)
        @test wm.current_idx == 1   # wraps
        Ressac.cmd_workspace!(wm, :prev)
        @test wm.current_idx == 3
    end
end

@testset "tile/float toggle" begin
    @testset "cmd_float! moves focused leaf to floats vector" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}()))
        ws.tree.current_tab = 1
        Ressac.cmd_vsplit!(wm, "log", Dict{String,Any}())
        # focused is now the new log leaf
        Ressac.cmd_float!(wm)
        @test length(ws.floats) == 1
        @test ws.floats[1].pane isa Ressac.LogPane
        @test ws.tree isa Ressac.PaneLeaf   # collapsed back to single editor leaf
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

    @testset "cmd_float! refuses when only one leaf left" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}()))
        ws.tree.current_tab = 1
        tree_before = ws.tree
        Ressac.cmd_float!(wm)
        @test ws.tree === tree_before
        @test isempty(ws.floats)
    end

    @testset "z_order increments on each cmd_float!" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}()))
        ws.tree.current_tab = 1
        Ressac.cmd_vsplit!(wm, "log", Dict{String,Any}())
        Ressac.cmd_float!(wm)
        # focus is back on editor; vsplit + float again
        Ressac.cmd_vsplit!(wm, "doc", Dict{String,Any}())
        Ressac.cmd_float!(wm)
        @test length(ws.floats) == 2
        @test ws.floats[2].z_order > ws.floats[1].z_order
    end
end
