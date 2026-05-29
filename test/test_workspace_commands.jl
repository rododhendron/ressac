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

@testset "workspace_keymap — pane mode dispatch" begin
    @testset "pane mode single-shot exits after one op" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}()))
        ws.tree.current_tab = 1

        Ressac._PANE_MODE.active = true
        Ressac._PANE_MODE.sticky = false
        @test Ressac._dispatch_pane_mode_key(wm, 'v') == true
        @test Ressac._PANE_MODE.active == false   # auto-exit
        @test ws.tree isa Ressac.Container         # vsplit took effect
    end

    @testset "pane mode sticky stays active after ops" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}()))
        ws.tree.current_tab = 1

        Ressac._PANE_MODE.active = true
        Ressac._PANE_MODE.sticky = true
        Ressac._dispatch_pane_mode_key(wm, 'v')
        @test Ressac._PANE_MODE.active == true
        Ressac._dispatch_pane_mode_key(wm, 'h')
        @test Ressac._PANE_MODE.active == true

        # Reset for downstream tests.
        Ressac._PANE_MODE.active = false
        Ressac._PANE_MODE.sticky = false
    end

    @testset "unknown char returns false, doesn't exit mode" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        push!(Ressac.current_workspace(wm).tree.tabs,
              Ressac._pane_new(:editor, Dict{String,Any}()))
        Ressac._PANE_MODE.active = true
        Ressac._PANE_MODE.sticky = false
        @test Ressac._dispatch_pane_mode_key(wm, 'z') == false
        @test Ressac._PANE_MODE.active == true     # not auto-exited
        Ressac._PANE_MODE.active = false
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
