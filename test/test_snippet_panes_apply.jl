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
            Dict("kind" => "log",    "role" => "side", "side" => "right"),
            Dict("kind" => "doc",    "role" => "side", "side" => "bottom",
                 "ref" => "gain"),
        ]
        Ressac.apply_snippet_panes!(wm, panes_spec, :starter)
        ws = Ressac.current_workspace(wm)
        @test ws.tree isa Ressac.Container
        leaves = Ressac._all_leaves(ws.tree)
        @test length(leaves) >= 3
        kinds = [typeof(leaf.tabs[1]) for leaf in leaves]
        @test Ressac.EditorPane in kinds
        @test Ressac.LogPane    in kinds
        @test Ressac.DocPane    in kinds
    end

    @testset "mode=block keeps current tree intact" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}()))
        ws.tree.current_tab = 1
        tree_before = ws.tree
        panes_spec = [Dict("kind" => "editor", "role" => "primary")]
        Ressac.apply_snippet_panes!(wm, panes_spec, :block)
        @test ws.tree === tree_before   # primary doesn't rebuild tree in block mode
    end

    @testset "bad kind warns + skips spec, rest applies" begin
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
        @test_logs (:warn, r"unregistered") match_mode=:any begin
            Ressac.apply_snippet_panes!(wm, panes_spec, :starter)
        end
        @test Ressac.current_workspace(wm).tree isa Ressac.Container
        leaves = Ressac._all_leaves(Ressac.current_workspace(wm).tree)
        # editor primary + log side (ghost was skipped)
        @test length(leaves) == 2
    end

    @testset "no primary spec → noop with warning" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}()))
        ws.tree.current_tab = 1
        tree_before = ws.tree
        panes_spec = [Dict("kind" => "log", "role" => "side", "side" => "right")]
        @test_logs (:warn, r"no primary") begin
            Ressac.apply_snippet_panes!(wm, panes_spec, :starter)
        end
        @test ws.tree === tree_before
    end
end

@testset "snippet panes — user config overrides" begin
    @testset "config override replaces snippet's panes spec" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        ws = Ressac.current_workspace(wm)
        push!(ws.tree.tabs, Ressac._pane_new(:editor, Dict{String,Any}()))
        ws.tree.current_tab = 1

        cfg = Ressac.RessacConfig()
        cfg.panes_overrides["test-snip"] = [
            Dict{String,Any}("kind" => "editor", "role" => "primary"),
            Dict{String,Any}("kind" => "doc", "role" => "side",
                              "side" => "right", "ref" => "gain"),
        ]
        prev = Ressac._RESSAC_CONFIG[]
        Ressac._RESSAC_CONFIG[] = cfg
        try
            # Snippet's own spec has only an editor primary; override
            # adds a side doc pane.
            snippet_panes = [Dict("kind" => "editor", "role" => "primary")]
            Ressac.apply_snippet_panes!(wm, snippet_panes, :starter;
                                        snippet_name = "test-snip")
            leaves = Ressac._all_leaves(Ressac.current_workspace(wm).tree)
            @test length(leaves) == 2   # editor + doc from override
        finally
            Ressac._RESSAC_CONFIG[] = prev
        end
    end

    @testset "empty snippet_name skips override lookup" begin
        wm = Ressac.WorkspaceManager()
        Ressac.create_workspace!(wm, "")
        push!(Ressac.current_workspace(wm).tree.tabs,
              Ressac._pane_new(:editor, Dict{String,Any}()))
        Ressac.current_workspace(wm).tree.current_tab = 1
        # Even if the config has an override for "" key (it won't), we
        # don't look it up when the snippet has no name.
        snippet_panes = [Dict("kind" => "editor", "role" => "primary")]
        Ressac.apply_snippet_panes!(wm, snippet_panes, :starter; snippet_name = "")
        leaves = Ressac._all_leaves(Ressac.current_workspace(wm).tree)
        @test length(leaves) == 1
    end
end
