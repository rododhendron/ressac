using Test
using Ressac
import Tachikoma

# test_pane_interface.jl vide _PANE_KINDS et ne ré-enregistre que les
# kinds core ; on ré-inclut le fichier du pane pour re-déclarer :explorer.
Base.include(Ressac, joinpath(@__DIR__, "..", "src", "pane_synth_explorer.jl"))

@testset "synth explorer pane — render" begin
    @testset "ctor builds a 9-candidate population from a seed" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "drone_grave", "rng" => 42))
        @test p isa Ressac.SynthExplorerPane
        @test length(p.pop.candidates) == 9
        @test p.focus == 1
    end

    @testset "title mentions the explorer + generation" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 1))
        @test occursin("explorer", lowercase(Ressac.title(p)))
    end

    @testset "render! draws the header + a structural summary" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "drone_grave", "rng" => 5))
        tb = Tachikoma.TestBackend(80, 24)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 80, 24), tb.buf)
        top = Tachikoma.row_text(tb, 1)
        @test occursin("EXPLORER", uppercase(top))
        whole = join((Tachikoma.row_text(tb, r) for r in 1:24))
        @test occursin("gén", whole) || occursin("gen", whole)
    end

    @testset "genome_summary names dominant ugens" begin
        g = Ressac.archetype(:drone_grave)
        s = Ressac._genome_summary(g)
        @test occursin("Saw", s) || occursin("RLPF", s)
    end

    @testset "v2 cards: mini-schema, cluster strip, cell rects" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "drone_grave", "rng" => 5))
        @test Ressac._genome_mini_schema(Ressac.archetype(:drone_grave)) == "Saw→RLPF"
        tb = Tachikoma.TestBackend(100, 30)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 100, 30), tb.buf)
        whole = join((Tachikoma.row_text(tb, r) for r in 1:30))
        @test occursin("gènes:", whole)
        @test occursin("clusters:", whole)
        @test occursin("→", whole)                    # a mini-schema arrow
        @test length(p.cell_rects) == 9               # hit-test rects filled
    end

    @testset "serialize captures seed + generation" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "pluck", "rng" => 9))
        d = Ressac.serialize(p)
        @test d["kind_seed"] == "pluck"
        @test haskey(d, "generation")
    end
end

@testset "synth explorer pane — interactions" begin
    mk() = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 7))

    @testset "l / h move focus horizontally" begin
        p = mk()
        @test Ressac.handle_key!(p, Tachikoma.KeyEvent('l')) == true
        @test p.focus == 2
        Ressac.handle_key!(p, Tachikoma.KeyEvent('h'))
        @test p.focus == 1
    end

    @testset "j / k move focus by a row (3 cols)" begin
        p = mk()
        Ressac.handle_key!(p, Tachikoma.KeyEvent('j'))
        @test p.focus == 4
        Ressac.handle_key!(p, Tachikoma.KeyEvent('k'))
        @test p.focus == 1
    end

    @testset "digit keys jump focus" begin
        p = mk()
        Ressac.handle_key!(p, Tachikoma.KeyEvent('5'))
        @test p.focus == 5
    end

    @testset "f favors, d devalues the focused candidate" begin
        p = mk()
        Ressac.handle_key!(p, Tachikoma.KeyEvent('f'))
        @test p.pop.candidates[1].weight > 0
        Ressac.handle_key!(p, Tachikoma.KeyEvent('5'))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('d'))
        @test p.pop.candidates[5].weight < 0
    end

    @testset "n advances the generation" begin
        p = mk()
        Ressac.handle_key!(p, Tachikoma.KeyEvent('f'))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('n'))
        @test p.pop.generation == 1
    end

    @testset "[ / ] adjust the divergence radius" begin
        p = mk()
        before = p.radius
        Ressac.handle_key!(p, Tachikoma.KeyEvent(']'))
        @test p.radius > before
        Ressac.handle_key!(p, Tachikoma.KeyEvent('['))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('['))
        @test p.radius < before
    end

    @testset "Space plays via the live scheduler (mock)" begin
        if !isdefined(Main, :MockOSCClient)
            mutable struct MockOSCClient; sent::Vector{Vector{UInt8}}; end
            MockOSCClient() = MockOSCClient(Vector{UInt8}[])
            Ressac.send_osc(c::MockOSCClient, b::Vector{UInt8}) = push!(c.sent, b)
        end
        mock = MockOSCClient()
        sched = Ressac.Scheduler(mock; cps = 0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            p = mk()
            Ressac.handle_key!(p, Tachikoma.KeyEvent(' '))
            @test length(mock.sent) >= 1
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "unhandled key returns false" begin
        p = mk()
        @test Ressac.handle_key!(p, Tachikoma.KeyEvent('Z')) == false
    end
end

@testset "synth explorer pane — keyboard + drone" begin
    # MockOSCClient est défini au top-level par test_synth_audition.jl
    # (inclus avant ce fichier dans runtests.jl).
    function _with_mock(f)
        mock = MockOSCClient()
        sched = Ressac.Scheduler(mock; cps = 0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            f(mock)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "m toggles keyboard sub-mode, Esc leaves it" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 3))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('m'))
        @test p.keyboard_mode == true
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:escape))
        @test p.keyboard_mode == false
    end

    @testset "in keyboard mode a note key plays (mock)" begin
        _with_mock() do mock
            p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 3))
            Ressac.handle_key!(p, Tachikoma.KeyEvent('m'))
            Ressac.handle_key!(p, Tachikoma.KeyEvent('z'))
            @test length(mock.sent) >= 1
            @test p.keyboard_mode == true
        end
    end

    @testset "t toggles drone hold (mock)" begin
        _with_mock() do mock
            p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 3))
            Ressac.handle_key!(p, Tachikoma.KeyEvent('t'))
            @test p.audition.held_active == true
            Ressac.handle_key!(p, Tachikoma.KeyEvent('t'))
            @test p.audition.held_active == false
        end
    end

    @testset "on_close! stops the drone (mock)" begin
        _with_mock() do mock
            p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 3))
            Ressac.handle_key!(p, Tachikoma.KeyEvent('t'))
            Ressac.on_close!(p)
            @test p.audition.held_active == false
        end
    end
end

@testset "synth explorer pane — details overlay" begin
    @testset "genome_depth measures the longest signal path" begin
        g = Ressac.archetype(:drone_grave)   # Saw -> RLPF
        @test Ressac._genome_depth(g) >= 2
    end

    @testset "i opens the overlay, Esc closes it" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 8))
        @test p.inspect == false
        Ressac.handle_key!(p, Tachikoma.KeyEvent('i'))
        @test p.inspect == true
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:escape))
        @test p.inspect == false
    end

    @testset "overlay renders the DSL + stats of the focused candidate" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "drone_grave", "rng" => 8))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('i'))
        tb = Tachikoma.TestBackend(80, 24)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 80, 24), tb.buf)
        whole = join((Tachikoma.row_text(tb, r) for r in 1:24))
        @test occursin("@synth", whole)
        @test occursin("nœuds", whole) || occursin("nodes", whole)
    end
end

@testset "synth explorer pane — commit save" begin
    @testset "s enters seed-naming mode, typing builds the name" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 2))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('s'))
        @test p.naming === :seed
        Ressac.handle_key!(p, Tachikoma.KeyEvent('a'))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('b'))
        @test p.name_buf == "ab"
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:escape))
        @test p.naming === :none
        @test p.name_buf == ""
    end

    @testset "Enter in seed mode writes a JSON seed" begin
        mktempdir() do dir
            p = Ressac._pane_new(:explorer, Dict{String,Any}(
                "seed" => "pluck", "rng" => 2))
            p.seed_dir_override = dir
            Ressac.handle_key!(p, Tachikoma.KeyEvent('s'))
            for c in "myseed"
                Ressac.handle_key!(p, Tachikoma.KeyEvent(c))
            end
            Ressac.handle_key!(p, Tachikoma.KeyEvent(:enter))
            @test isfile(joinpath(dir, "myseed.json"))
            @test p.naming === :none
        end
    end

    @testset "Enter in synth mode writes a .jl DSL file" begin
        mktempdir() do dir
            p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 2))
            p.user_synth_dir_override = dir
            Ressac.handle_key!(p, Tachikoma.KeyEvent('w'))
            @test p.naming === :synth
            for c in "wobz"
                Ressac.handle_key!(p, Tachikoma.KeyEvent(c))
            end
            Ressac.handle_key!(p, Tachikoma.KeyEvent(:enter))
            path = joinpath(dir, "wobz.jl")
            @test isfile(path)
            @test occursin("@synth", read(path, String))
        end
    end
end

@testset "synth explorer pane — session persistence" begin
    @testset ":explorer is a registered pane kind" begin
        @test haskey(Ressac._PANE_KINDS, :explorer)
    end

    @testset "serialize captures the full population" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "pluck", "rng" => 3))
        Ressac.favor!(p.pop, 2)
        d = Ressac.serialize(p)
        @test haskey(d, "population")
        @test length(d["population"]) == 9
    end

    @testset "round-trip restores candidates + weights + generation" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "pluck", "rng" => 3))
        Ressac.favor!(p.pop, 2)
        Ressac.handle_key!(p, Tachikoma.KeyEvent('f'))
        gen_before = p.pop.generation
        d = Ressac.serialize(p)
        p2 = Ressac._pane_new(:explorer, d)
        @test length(p2.pop.candidates) == 9
        @test p2.pop.generation == gen_before
        @test p2.pop.candidates[2].weight > 0
        s1 = Ressac.render_synthdef(p.pop.candidates[5].genome, :x)
        s2 = Ressac.render_synthdef(p2.pop.candidates[5].genome, :x)
        @test s1 == s2
    end
end

@testset "synth explorer pane — export to editor" begin
    @testset "e enters export-naming mode; Enter posts a request" begin
        Ressac._EXPLORER_EXPORT_REQUEST[] = nothing
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "pluck", "rng" => 4))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('e'))
        @test p.naming === :export
        for c in "mywob"
            Ressac.handle_key!(p, Tachikoma.KeyEvent(c))
        end
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:enter))
        req = Ressac._EXPLORER_EXPORT_REQUEST[]
        @test req !== nothing
        @test req[1] == "mywob"
        @test occursin("@synth", req[2])
        Ressac._EXPLORER_EXPORT_REQUEST[] = nothing
    end

    @testset "_drain_explorer_export! opens an editor tab with the DSL" begin
        mock = MockOSCClient()
        sched = Ressac.Scheduler(mock; cps = 0.5)
        app = Ressac.RessacApp(; scheduler = sched)
        Ressac._ensure_default_workspace!(app)
        Ressac._EXPLORER_EXPORT_REQUEST[] = ("expsynth", "@synth :expsynth saw(:freq)")
        @test Ressac._drain_explorer_export!(app) == true
        @test Ressac._EXPLORER_EXPORT_REQUEST[] === nothing
        ws = Ressac.current_workspace(app.workspaces)
        found = false
        for leaf in Ressac._collect_panes!(Ressac.PaneImpl[], ws.tree)
            if leaf isa Ressac.EditorPane
                for t in leaf.tabs
                    occursin("expsynth", Tachikoma.text(t.code_editor)) && (found = true)
                end
            end
        end
        @test found
    end
end

@testset "synth explorer pane — end-to-end via Tachikoma.update!" begin
    # _new_app() est défini au top-level par test_ui_integration.jl
    # (inclus avant ce fichier dans runtests.jl).
    @testset "keys route app→pane through _route_key_to_focused_pane!" begin
        app, _ = _new_app()
        Ressac.cmd_vsplit!(app.workspaces, "explorer",
                           Dict{String,Any}("rng" => 5))
        ws = Ressac.current_workspace(app.workspaces)
        leaf = Ressac._find_leaf_by_id(ws.tree, ws.focused_pane)
        pane = leaf.tabs[leaf.current_tab]
        @test pane isa Ressac.SynthExplorerPane
        Ressac._active_editor(app).mode = :normal
        # navigation routée jusqu'au pane
        Tachikoma.update!(app, Tachikoma.KeyEvent('l'))
        @test pane.focus == 2
        # favoriser puis avancer d'une génération, le tout via update!
        Tachikoma.update!(app, Tachikoma.KeyEvent('f'))
        @test pane.pop.candidates[2].weight > 0
        Tachikoma.update!(app, Tachikoma.KeyEvent('n'))
        @test pane.pop.generation == 1
    end

    @testset "export e flows update!→drain→new editor tab" begin
        Ressac._EXPLORER_EXPORT_REQUEST[] = nothing
        app, _ = _new_app()
        Ressac.cmd_vsplit!(app.workspaces, "explorer",
                           Dict{String,Any}("rng" => 6))
        ws = Ressac.current_workspace(app.workspaces)
        leaf = Ressac._find_leaf_by_id(ws.tree, ws.focused_pane)
        pane = leaf.tabs[leaf.current_tab]
        Ressac._active_editor(app).mode = :normal
        n_editors_before = count(p -> p isa Ressac.EditorPane,
            Ressac._collect_panes!(Ressac.PaneImpl[], ws.tree))
        # e → saisie du nom → Enter : poste la requête + draine via update!
        Tachikoma.update!(app, Tachikoma.KeyEvent('e'))
        @test pane.naming === :export
        for c in "fromupd"
            Tachikoma.update!(app, Tachikoma.KeyEvent(c))
        end
        Tachikoma.update!(app, Tachikoma.KeyEvent(:enter))
        # la requête a été drainée par le routeur de touches
        @test Ressac._EXPLORER_EXPORT_REQUEST[] === nothing
        ws2 = Ressac.current_workspace(app.workspaces)
        found = false
        for lf in Ressac._collect_panes!(Ressac.PaneImpl[], ws2.tree)
            lf isa Ressac.EditorPane || continue
            for t in lf.tabs
                occursin("fromupd", Tachikoma.text(t.code_editor)) && (found = true)
            end
        end
        @test found
    end
end

@testset "synth explorer pane — GA settings panel (g)" begin
    @testset "g opens the panel, Esc closes" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 4))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('g'))
        @test p.ga_panel == true
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:escape))
        @test p.ga_panel == false
    end

    @testset "←/→ adjust the selected GA param" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 4))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('g'))
        # row 1 = gen_size
        before = p.pop.gen_size
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:left))
        @test p.pop.gen_size == before - 1
        # move to row 3 (crossover) and bump it
        Ressac.handle_key!(p, Tachikoma.KeyEvent('j'))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('j'))
        xb = p.pop.crossover_prob
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:right))
        @test p.pop.crossover_prob > xb
    end

    @testset "gen_size is bounded to the audition pool" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 4))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('g'))
        for _ in 1:20
            Ressac.handle_key!(p, Tachikoma.KeyEvent(:right))   # row 1
        end
        @test p.pop.gen_size <= 9
        for _ in 1:20
            Ressac.handle_key!(p, Tachikoma.KeyEvent(:left))
        end
        @test p.pop.gen_size >= 2
    end

    @testset "panel renders the rows" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 4))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('g'))
        tb = Tachikoma.TestBackend(100, 30)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 100, 30), tb.buf)
        whole = join((Tachikoma.row_text(tb, r) for r in 1:30))
        @test occursin("RÉGLAGES GA", whole)
        @test occursin("croisement", whole)
    end
end

@testset "synth explorer pane — lineage + help overlays" begin
    @testset "L opens lineage, shows origin chain" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 3))
        Ressac.favor!(p.pop, 1)
        Ressac._explorer_next_gen!(p)        # gen 1, candidates have parents
        Ressac.handle_key!(p, Tachikoma.KeyEvent('L'))
        @test p.show_lineage == true
        tb = Tachikoma.TestBackend(100, 30)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 100, 30), tb.buf)
        whole = join((Tachikoma.row_text(tb, r) for r in 1:30))
        @test occursin("LIGNÉE", whole)
        @test occursin("gén", whole)
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:escape))
        @test p.show_lineage == false
    end

    @testset "? opens help overlay, Esc closes" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 3))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('?'))
        @test p.show_help == true
        tb = Tachikoma.TestBackend(100, 30)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 100, 30), tb.buf)
        whole = join((Tachikoma.row_text(tb, r) for r in 1:30))
        @test occursin("aide", whole)
        @test occursin("mini-clavier", whole)
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:escape))
        @test p.show_help == false
    end
end

@testset "synth explorer pane — mouse" begin
    # render first so cell_rects is populated, then hit-test.
    function _rendered()
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 5))
        tb = Tachikoma.TestBackend(100, 30)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 100, 30), tb.buf)
        return p
    end
    mev(x, y, btn, act = Tachikoma.mouse_press) =
        Tachikoma.MouseEvent(x, y, btn, act, false, false, false)

    @testset "left-click focuses + plays the clicked card (mock)" begin
        mock = MockOSCClient()
        sched = Ressac.Scheduler(mock; cps = 0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            p = _rendered()
            (idx, (cx, cy, cw, ch)) = p.cell_rects[5]
            Ressac.handle_mouse!(p, mev(cx + 1, cy + 1, Tachikoma.mouse_left))
            @test p.focus == idx
            @test length(mock.sent) >= 1
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "scroll up/down favors/devalues the hovered card" begin
        p = _rendered()
        (idx, (cx, cy, cw, ch)) = p.cell_rects[2]
        Ressac.handle_mouse!(p, mev(cx + 1, cy + 1, Tachikoma.mouse_scroll_up))
        @test p.pop.candidates[idx].weight > 0
        Ressac.handle_mouse!(p, mev(cx + 1, cy + 1, Tachikoma.mouse_scroll_down))
        @test p.pop.candidates[idx].weight < 0
    end

    @testset "right-click advances the generation" begin
        p = _rendered()
        Ressac.handle_mouse!(p, mev(2, 2, Tachikoma.mouse_right))
        @test p.pop.generation == 1
    end

    @testset "click outside any card is ignored" begin
        p = _rendered()
        @test Ressac.handle_mouse!(p, mev(999, 999, Tachikoma.mouse_left)) == false
    end
end

@testset "synth explorer pane — scroll-to-rate via the app" begin
    # _new_app() is defined in test_ui_integration.jl (loaded earlier);
    # :explorer is registered because this file re-includes the pane.
    @testset "scroll over a card favors/devalues the hovered candidate" begin
        app, frame = _new_app()
        Ressac.cmd_vsplit!(app.workspaces, "explorer", Dict{String,Any}("rng" => 5))
        Tachikoma.view(app, frame)              # fills _last_ws_area + cell_rects
        ws = Ressac.current_workspace(app.workspaces)
        leaf = Ressac._find_leaf_by_id(ws.tree, ws.focused_pane)
        pane = leaf.tabs[leaf.current_tab]
        @test pane isa Ressac.SynthExplorerPane
        @test !isempty(pane.cell_rects)
        (idx, (cx, cy, cw, ch)) = pane.cell_rects[2]
        mev(btn) = Tachikoma.MouseEvent(cx + 1, cy + 1, btn, Tachikoma.mouse_press,
                                        false, false, false)
        @test Ressac._workspace_scroll_to_pane!(app, mev(Tachikoma.mouse_scroll_up)) == true
        @test pane.pop.candidates[idx].weight > 0
        @test Ressac._workspace_scroll_to_pane!(app, mev(Tachikoma.mouse_scroll_down)) == true
        @test pane.pop.candidates[idx].weight < 0
    end
end
