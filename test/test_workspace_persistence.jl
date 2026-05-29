using Test
using TOML
using Ressac

@testset "workspace_persistence" begin
    @testset "save → load round-trip preserves single editor workspace" begin
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
            @test isfile(path)
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

    @testset "save → load round-trip preserves a split layout" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "split")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}()))
        ws.tree.current_tab = 1
        Ressac.cmd_vsplit!(wm, "log", Dict{String,Any}())
        tmp = mktempdir()
        try
            path = joinpath(tmp, "layout.toml")
            Ressac.save_layout(wm, path)
            wm2 = Ressac.WorkspaceManager()
            Ressac.load_layout!(wm2, path)
            tree = wm2.workspaces[1].tree
            @test tree isa Ressac.Container
            @test length(tree.children) == 2
            @test tree.direction === :h
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

    @testset "load on missing file warns + leaves manager empty" begin
        wm = Ressac.WorkspaceManager()
        @test_logs (:warn, r"not found") begin
            Ressac.load_layout!(wm, "/nonexistent/path/layout.toml")
        end
        @test isempty(wm.workspaces)
    end

    @testset "load on corrupted TOML warns + leaves manager empty" begin
        wm = Ressac.WorkspaceManager()
        tmp = mktempdir()
        try
            path = joinpath(tmp, "bad.toml")
            write(path, "totally not = valid = toml [[[")
            @test_logs (:warn, r"parse failed") begin
                Ressac.load_layout!(wm, path)
            end
            @test isempty(wm.workspaces)
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

    @testset "load fixture round-trip" begin
        fixture = joinpath(@__DIR__, "fixtures", "layouts", "sample_layout.toml")
        wm = Ressac.WorkspaceManager()
        Ressac.load_layout!(wm, fixture)
        @test length(wm.workspaces) == 1
        @test wm.workspaces[1].name == "live"
    end
end
