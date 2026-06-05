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

    @testset "v2 cards: DAG tree, cluster strip, cell rects" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "drone_grave", "rng" => 5))
        @test Ressac._genome_mini_schema(Ressac.archetype(:drone_grave)) == "Saw→RLPF"
        tb = Tachikoma.TestBackend(100, 30)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 100, 30), tb.buf)
        whole = join((Tachikoma.row_text(tb, r) for r in 1:30))
        @test occursin("gènes:", whole)
        @test occursin("clusters:", whole)
        # la case montre maintenant le DAG (arbre), comme les détails
        @test occursin("RLPF", whole) || occursin("Saw", whole)   # UGen names
        @test occursin("└─", whole)                               # tree connector
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

    @testset "overlay renders the DAG tree + stats of the focused candidate" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "drone_grave", "rng" => 8))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('i'))
        tb = Tachikoma.TestBackend(80, 24)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 80, 24), tb.buf)
        whole = join((Tachikoma.row_text(tb, r) for r in 1:24))
        @test occursin("DAG", whole)
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
        @test occursin("stratégie", whole)
    end

    @testset "strategy row cycles through GA_STRATEGIES" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 4))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('g'))
        @test p.pop.strategy === :bayesian        # défaut = active inference
        for _ in 1:4
            Ressac.handle_key!(p, Tachikoma.KeyEvent('j'))   # to row 5 (stratégie)
        end
        s0 = p.pop.strategy
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:right))
        @test p.pop.strategy !== s0
        @test p.pop.strategy in Ressac.GA_STRATEGIES
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

    @testset "scroll up/down grades the hovered card (cumulative)" begin
        p = _rendered()
        (idx, (cx, cy, cw, ch)) = p.cell_rects[2]
        Ressac.handle_mouse!(p, mev(cx + 1, cy + 1, Tachikoma.mouse_scroll_up))
        Ressac.handle_mouse!(p, mev(cx + 1, cy + 1, Tachikoma.mouse_scroll_up))
        @test p.pop.candidates[idx].weight == 2.0          # graded up
        for _ in 1:4
            Ressac.handle_mouse!(p, mev(cx + 1, cy + 1, Tachikoma.mouse_scroll_down))
        end
        @test p.pop.candidates[idx].weight < 0             # graded down past zero
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
        for _ in 1:3
            @test Ressac._workspace_scroll_to_pane!(app, mev(Tachikoma.mouse_scroll_down)) == true
        end
        @test pane.pop.candidates[idx].weight < 0
    end
end

@testset "synth explorer pane — per-candidate param editor (p)" begin
    @testset "p opens, j/k navigate, ←/→ edit, Esc closes" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 6))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('p'))
        @test p.param_edit == true
        g = p.pop.candidates[p.focus].genome
        f0 = Ressac.control(g, :freq)              # row 1 = freq
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:right))
        @test Ressac.control(g, :freq) > f0
        # move to sustain (row 2) and bump
        Ressac.handle_key!(p, Tachikoma.KeyEvent('j'))
        s0 = Ressac.control(g, :sustain)
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:right))
        @test Ressac.control(g, :sustain) > s0
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:escape))
        @test p.param_edit == false
    end

    @testset "r resets the focused candidate's controls" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 6))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('p'))
        g = p.pop.candidates[p.focus].genome
        g.controls[:freq] = 1234.0
        Ressac.handle_key!(p, Tachikoma.KeyEvent('r'))
        @test Ressac.control(g, :freq) == Ressac.default_controls()[:freq]
    end

    @testset "edits ride along into the algorithm (via lineage)" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 6))
        p.pop.candidates[1].genome.controls[:freq] = 99.0
        champ_id = p.pop.candidates[1].id
        Ressac.favor!(p.pop, 1)
        p.pop.strategy = :champion       # all children descend from candidate 1
        Ressac.next_generation!(p.pop, p.rng)
        # the edited candidate re-entered the algorithm as the parent;
        # mutation then perturbs the inherited freq around 99 (pitch variety).
        @test all(c -> p.pop.lineage[c.id].parents == [champ_id], p.pop.candidates)
        @test any(c -> Ressac.control(c.genome, :freq) != 220.0, p.pop.candidates)
    end

    @testset "param editor renders the control rows" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 6))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('p'))
        tb = Tachikoma.TestBackend(100, 30)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 100, 30), tb.buf)
        whole = join((Tachikoma.row_text(tb, r) for r in 1:30))
        @test occursin("PARAMS", whole)
        @test occursin("release", whole)
    end
end

@testset "synth explorer pane — yank candidate DSL" begin
    @testset "yank text is the focused candidate's DSL" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("seed" => "pluck", "rng" => 3))
        txt = Ressac._explorer_yank_text(p)
        @test occursin("@synth", txt)
        @test occursin("ugen(", txt)        # clean multi-line DSL, not a Sig string
        @test !occursin("Sig(\"", txt)
    end

    @testset "y logs a clipboard result, never crashes" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 3))
        n0 = length(Ressac._APP_LOG[])
        @test Ressac.handle_key!(p, Tachikoma.KeyEvent('y')) == true
        @test length(Ressac._APP_LOG[]) == n0 + 1
        @test occursin("presse-papier", Ressac._APP_LOG[][end])
    end
end

@testset "synth explorer pane — regenerate silent candidates (S)" begin
    @testset "S replaces measured-silent candidates" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 7))
        Ressac._reset_slot_levels!(9)
        # candidate 3 measured silent, candidate 1 audible
        Ressac._handle_synth_level!(Any[1, 1, 1, 0.4])
        Ressac._handle_synth_level!(Any[1, 1, 3, 0.0])
        Ressac._GA_SLOT_MEASURED[][3] = true
        id3_before = p.pop.candidates[3].id
        id1_before = p.pop.candidates[1].id
        Ressac.handle_key!(p, Tachikoma.KeyEvent('S'))
        @test p.pop.candidates[3].id != id3_before          # silent one replaced
        @test occursin("régénéré", p.pop.candidates[3].origin)
        @test p.pop.candidates[1].id == id1_before          # audible one untouched
        @test Ressac.genome_is_audible(p.pop.candidates[3].genome)
    end
end

@testset "explorer survives a layout save/load round-trip" begin
    wm = Ressac.WorkspaceManager()
    Ressac.create_workspace!(wm, "")
    ws = Ressac.current_workspace(wm)
    push!(ws.tree.tabs, Ressac._pane_new(:explorer,
        Dict{String,Any}("seed" => "pluck", "rng" => 5)))
    ws.tree.current_tab = 1
    Ressac.favor!(ws.tree.tabs[1].pop, 2)
    @test Ressac._kind_for(ws.tree.tabs[1]) == "explorer"
    mktempdir() do d
        path = joinpath(d, "layout.toml")
        Ressac.save_layout(wm, path)
        wm2 = Ressac.WorkspaceManager()
        Ressac.load_layout!(wm2, path)
        ws2 = Ressac.current_workspace(wm2)
        pane = ws2.tree.tabs[ws2.tree.current_tab]
        @test pane isa Ressac.SynthExplorerPane
        @test length(pane.pop.candidates) == 9
        @test pane.pop.candidates[2].weight > 0     # favorite preserved
    end
end

@testset "synth explorer pane — quick strategy switch + diverge" begin
    @testset "Tab cycles the strategy live" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 9))
        s0 = p.pop.strategy
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:tab))
        @test p.pop.strategy != s0
        @test p.pop.strategy in Ressac.GA_STRATEGIES
    end

    @testset "header shows the active strategy" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 9))
        tb = Tachikoma.TestBackend(100, 30)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 100, 30), tb.buf)
        top = Tachikoma.row_text(tb, 1)
        @test occursin("pool", top) || occursin("Tab", top)
    end

    @testset "R re-diverges (advances generation, all audible)" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 9))
        Ressac.favor!(p.pop, 1)
        Ressac._explorer_next_gen!(p)
        g0 = p.pop.generation
        Ressac.handle_key!(p, Tachikoma.KeyEvent('R'))
        @test p.pop.generation == g0 + 1
        @test all(c -> Ressac.genome_is_audible(c.genome), p.pop.candidates)
    end
end

@testset "synth explorer pane — tune/brew toggle (T)" begin
    @testset "T flips the mode, default is brew" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 9))
        @test p.mode === :brew
        Ressac.handle_key!(p, Tachikoma.KeyEvent('T'))
        @test p.mode === :tune
        Ressac.handle_key!(p, Tachikoma.KeyEvent('T'))
        @test p.mode === :brew
    end

    @testset "n in tune mode keeps every candidate's structure frozen" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("seed" => "drone_grave", "rng" => 9))
        p.focus = 2
        anchor_ugens = sort([String(n.ugen) for n in values(p.pop.candidates[2].genome.nodes)])
        Ressac.handle_key!(p, Tachikoma.KeyEvent('T'))     # → tune
        Ressac.handle_key!(p, Tachikoma.KeyEvent('n'))     # générer
        @test p.pop.generation == 1
        for c in p.pop.candidates
            @test sort([String(n.ugen) for n in values(c.genome.nodes)]) == anchor_ugens
        end
    end

    @testset "header shows the TUNE badge in tune mode" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 9))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('T'))
        tb = Tachikoma.TestBackend(100, 30)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 100, 30), tb.buf)
        @test occursin("TUNE", Tachikoma.row_text(tb, 1))
    end
end

@testset "synth explorer pane — DAG tree details + reset" begin
    @testset "inspect overlay shows the DAG tree, not raw code" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("seed" => "drone_grave", "rng" => 5))
        lines = Ressac._genome_tree_lines(Ressac.archetype(:drone_grave))
        @test any(l -> occursin("RLPF", l), lines)
        @test any(l -> occursin("└─", l) || occursin("├─", l), lines)   # tree branches
        Ressac.handle_key!(p, Tachikoma.KeyEvent('i'))
        tb = Tachikoma.TestBackend(100, 30)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 100, 30), tb.buf)
        whole = join((Tachikoma.row_text(tb, r) for r in 1:30))
        @test occursin("DAG des opérations", whole)
        @test !occursin("@synth", whole)        # no raw DSL dump anymore
    end

    @testset "0 resets the explorer to a fresh gen-0 population" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 5))
        Ressac.favor!(p.pop, 1)
        Ressac._explorer_next_gen!(p)
        @test p.pop.generation > 0
        Ressac.handle_key!(p, Tachikoma.KeyEvent('0'))
        @test p.pop.generation == 0
        @test length(p.pop.candidates) == 9
        @test all(c -> c.weight == 0.0, p.pop.candidates)
    end
end

@testset "synth explorer pane — guidance (good move + direction)" begin
    @testset "G grafts a good move onto the focused candidate" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("seed" => "drone_grave", "rng" => 7))
        n0 = length(p.pop.candidates[p.focus].genome.nodes)
        Ressac.handle_key!(p, Tachikoma.KeyEvent('G'))
        @test length(p.pop.candidates[p.focus].genome.nodes) > n0
        @test Ressac.genome_is_audible(p.pop.candidates[p.focus].genome)
    end

    @testset "< > cycle the guidance direction (shown in header)" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 7))
        @test p.guidance_dir === :none
        Ressac.handle_key!(p, Tachikoma.KeyEvent('>'))
        @test p.guidance_dir !== :none
        @test p.guidance_dir in Ressac.GUIDANCE_ORDER
        tb = Tachikoma.TestBackend(110, 30)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 110, 30), tb.buf)
        @test occursin("→", Tachikoma.row_text(tb, 1))
    end

    @testset "grave guidance yields a lower-pitched generation (vs none)" begin
        meanfreq(p) = sum(Ressac.control(c.genome, :freq) for c in p.pop.candidates) /
                      length(p.pop.candidates)
        # same seed → identical mutations; grave applies ×0.8 on top.
        p1 = Ressac._pane_new(:explorer, Dict{String,Any}("seed" => "drone_grave", "rng" => 7))
        p2 = Ressac._pane_new(:explorer, Dict{String,Any}("seed" => "drone_grave", "rng" => 7))
        Ressac.favor!(p1.pop, 1); Ressac.favor!(p2.pop, 1)
        p1.guidance_dir = :grave
        Ressac._explorer_next_gen!(p1)
        Ressac._explorer_next_gen!(p2)
        @test meanfreq(p1) < meanfreq(p2)
    end
end

@testset "synth explorer pane — usage role targeting (UI)" begin
    @testset "u cycles the role; header reflects it" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 9))
        @test get(p.pop.state, :role, nothing) === nothing
        Ressac.handle_key!(p, Tachikoma.KeyEvent('u'))
        @test get(p.pop.state, :role, nothing) === Ressac.ROLE_ORDER[1]
        tb = Tachikoma.TestBackend(110, 30)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 110, 30), tb.buf)
        @test occursin(String(Ressac.ROLE_ORDER[1]), Tachikoma.row_text(tb, 1))
    end

    @testset "card shows measured role-fit (♪) when role active" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("seed" => "drone_grave", "rng" => 9))
        p.pop.state[:role] = :basse
        store = Ressac._descr_store(p.pop)
        for c in p.pop.candidates
            store[c.id] = copy(Ressac.role(:basse).target)   # match parfait → ♪100
        end
        tb = Tachikoma.TestBackend(110, 30)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 110, 30), tb.buf)
        whole = join((Tachikoma.row_text(tb, r) for r in 1:30))
        @test occursin("♪", whole)
    end

    @testset "+ tags the focused candidate for mode C refine" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 9))
        p.pop.state[:role] = :basse
        Ressac._descr_store(p.pop)[p.pop.candidates[p.focus].id] =
            [0.0, 1.0, 0.0, 0.4, 0.8, 1.0]
        @test Ressac.handle_key!(p, Tachikoma.KeyEvent('+')) == true
        ex = p.pop.state[:role_examples][:basse]
        @test length(ex.pos) == 1
    end

    @testset "H runs a harvest with an injected analyzer (no sclang)" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("seed" => "drone_grave", "rng" => 9))
        p.pop.state[:role] = :basse
        prev = Ressac._EXPLORER_ANALYZE[]
        Ressac._EXPLORER_ANALYZE[] = genomes -> [copy(Ressac.role(:basse).target) for _ in genomes]
        try
            g0 = p.pop.generation
            @test Ressac.handle_key!(p, Tachikoma.KeyEvent('H')) == true
            @test p.pop.generation == g0 + 1
            @test length(p.pop.candidates) == Ressac._GA_GEN_SIZE
            @test all(c -> haskey(p.pop.state[:descr], c.id), p.pop.candidates)
        finally
            Ressac._EXPLORER_ANALYZE[] = prev
        end
    end

    @testset "GA panel adjusts role strength λ (row 9)" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 9))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('g'))
        for _ in 1:8; Ressac.handle_key!(p, Tachikoma.KeyEvent('j')); end   # → row 9
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:right))
        @test get(p.pop.state, :role_strength, 1.0) > 1.0
    end
end

@testset "synth explorer pane — V posts a waveform request" begin
    p = Ressac._pane_new(:explorer, Dict{String,Any}("seed" => "drone_grave", "rng" => 9))
    Ressac._EXPLORER_WAVEFORM_REQUEST[] = nothing
    p.focus = 3
    @test Ressac.handle_key!(p, Tachikoma.KeyEvent('V')) == true
    req = Ressac._EXPLORER_WAVEFORM_REQUEST[]
    @test req !== nothing
    @test occursin("#3", req[2])                       # label = candidat #3
    # le génome sérialisé se redéserialise
    g = Ressac.deserialize_genome(req[1])
    @test g isa Ressac.Genome
    Ressac._EXPLORER_WAVEFORM_REQUEST[] = nothing
end

@testset "synth explorer pane — explainer overlay (x)" begin
    @testset "x opens the explainer (composantes + explication), Esc closes" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("seed" => "drone_grave", "rng" => 9))
        @test p.show_explain == false
        Ressac.handle_key!(p, Tachikoma.KeyEvent('x'))
        @test p.show_explain == true
        tb = Tachikoma.TestBackend(100, 30)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 100, 30), tb.buf)
        whole = join((Tachikoma.row_text(tb, r) for r in 1:30))
        @test occursin("EXPLAIN", whole) && occursin("COMPOSANTES", whole)
        @test occursin("SYNTHÈSE", whole) || occursin("POURQUOI", whole)
        @test occursin("son complet", whole)
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:escape))
        @test p.show_explain == false
    end

    @testset "j/k navigates components; a part shows its own explanation" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("seed" => "drone_grave", "rng" => 9))
        # génome connu multi-composantes : Saw → RLPF
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        f = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                             Ressac.ConstArg(800.0), Ressac.ConstArg(0.3)])
        g.output_id = f
        p.pop.candidates[p.focus].genome = g
        @test length(Ressac.decompose(g)) >= 2
        p.show_explain = true
        @test p.explain_cursor == 1
        Ressac.handle_key!(p, Tachikoma.KeyEvent('j'))   # → composante 2
        @test p.explain_cursor == 2
        tb = Tachikoma.TestBackend(100, 30)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 100, 30), tb.buf)
        whole = join((Tachikoma.row_text(tb, r) for r in 1:30))
        @test occursin("matière", whole)            # la 2e composante = la source
    end

    @testset "measured descriptors feed the full-sound explanation" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("seed" => "drone_grave", "rng" => 9))
        p.pop.state[:descr] = Dict{Int,Vector{Float64}}(
            p.pop.candidates[p.focus].id => [0.1, 0.85, 0.05, 0.4, 0.8, 0.95])
        p.show_explain = true                        # curseur=1 → son complet
        tb = Tachikoma.TestBackend(100, 30)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 100, 30), tb.buf)
        whole = join((Tachikoma.row_text(tb, r) for r in 1:30))
        @test occursin("sombre", whole) || occursin("basse", whole)   # indice acoustique mesuré
    end

    @testset "Space solos the selected component via the scheduler (mock)" begin
        mock = MockOSCClient()
        sched = Ressac.Scheduler(mock; cps = 0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            p = Ressac._pane_new(:explorer, Dict{String,Any}("seed" => "drone_grave", "rng" => 9))
            p.show_explain = true
            n0 = length(mock.sent)
            Ressac.handle_key!(p, Tachikoma.KeyEvent(' '))
            @test length(mock.sent) > n0
            @test p.audition.held_active == true
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "V posts a waveform request for the selected component" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("seed" => "drone_grave", "rng" => 9))
        p.show_explain = true
        Ressac.handle_key!(p, Tachikoma.KeyEvent('j'))   # composante 2 (matière)
        Ressac._EXPLORER_WAVEFORM_REQUEST[] = nothing
        @test Ressac.handle_key!(p, Tachikoma.KeyEvent('V')) == true
        @test Ressac._EXPLORER_WAVEFORM_REQUEST[] !== nothing
        Ressac._EXPLORER_WAVEFORM_REQUEST[] = nothing
    end
end
