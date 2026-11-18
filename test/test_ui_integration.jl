include(joinpath(@__DIR__, "helpers.jl"))
# UI integration tests — drive a real RessacApp via Tachikoma.update!
# and assert end-to-end outcomes. The pattern stays small: build the
# app, ship a sequence of KeyEvent / MouseEvent, check state. Each
# test reads like a user gesture sequence so a regression makes the
# offending flow obvious.

using Test
using Ressac
import Tachikoma

# Find the EditorPane that holds Ressac._active_editor(m) (the patterns pane) in
# the focused workspace's tree. Returns the leaf id.
function _patterns_leaf_id(app::Ressac.RessacApp)
    ws = Ressac.current_workspace(app.workspaces)
    for leaf in Ressac._all_leaves(ws.tree)
        for tab in leaf.tabs
            if tab isa Ressac.EditorPane &&
               !isempty(tab.tabs) &&
               tab.tabs[tab.current_tab].code_editor === Ressac._active_editor(app)
                return leaf.id
            end
        end
    end
    return 0
end

# ── Pane creation + isolation ───────────────────────────────────────

@testset "C-w v creates a new pane and persists pane mode" begin
    app, _ = _new_app()
    Ressac._active_editor(app).mode = :normal
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w'))
    @test Ressac._PANE_MODE.active == true
    Tachikoma.update!(app, Tachikoma.KeyEvent('v'))
    Tachikoma.update!(app, Tachikoma.KeyEvent('v'))
    Tachikoma.update!(app, Tachikoma.KeyEvent('v'))
    ws = Ressac.current_workspace(app.workspaces)
    @test length(collect(Ressac._all_leaves(ws.tree))) == 4
    @test Ressac._PANE_MODE.active == true   # still in pane mode
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    @test Ressac._PANE_MODE.active == false
end

@testset "typing isolation — split, type, switch, type" begin
    app, frame = _new_app()
    # Snapshot the original (patterns) editor BEFORE the split so we
    # can compare buffers per-pane.
    Ressac._active_editor(app).mode = :normal
    Ressac.TK.set_text!(Ressac._active_editor(app), "")
    original_editor = Ressac._active_editor(app)
    # Split off a new editor pane and focus it.
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w'))
    Tachikoma.update!(app, Tachikoma.KeyEvent('v'))
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    Tachikoma.view(app, frame)  # refresh focus flags + rects

    ws = Ressac.current_workspace(app.workspaces)
    new_editor = Ressac._active_editor(app)  # focused = the new pane
    @test new_editor !== original_editor

    # Type in the focused (new) pane.
    Tachikoma.update!(app, Tachikoma.KeyEvent('i'))
    _type!(app, "hello-new")
    @test occursin("hello-new", Ressac.TK.text(new_editor))
    @test !occursin("hello-new", Ressac.TK.text(original_editor))

    # Switch focus back to the original pane (h = focus left).
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w'))
    Tachikoma.update!(app, Tachikoma.KeyEvent('h'))
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    Tachikoma.view(app, frame)
    @test Ressac._active_editor(app) === original_editor

    Tachikoma.update!(app, Tachikoma.KeyEvent('i'))
    _type!(app, "hello-main")
    @test occursin("hello-main", Ressac.TK.text(original_editor))
    @test !occursin("hello-main", Ressac.TK.text(new_editor))
end

@testset "C-w + arrow keys navigate focus (same as hjkl)" begin
    app, frame = _new_app()
    Ressac._active_editor(app).mode = :normal
    Ressac.cmd_vsplit!(app.workspaces, "editor", Dict{String,Any}())
    Ressac.cmd_focus!(app.workspaces, :left)
    Tachikoma.view(app, frame)
    ws = Ressac.current_workspace(app.workspaces)
    start = ws.focused_pane
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w'))
    Tachikoma.update!(app, Tachikoma.KeyEvent(:right))
    @test ws.focused_pane != start
    Tachikoma.update!(app, Tachikoma.KeyEvent(:left))
    @test ws.focused_pane == start
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
end

@testset "C-w h/j/k/l navigates focus in a 2×2 grid" begin
    app, frame = _new_app()
    Ressac._active_editor(app).mode = :normal
    # Build a 2×2 grid: vsplit then hsplit on both columns.
    Ressac.cmd_vsplit!(app.workspaces, "editor", Dict{String,Any}())
    Ressac.cmd_hsplit!(app.workspaces, "editor", Dict{String,Any}())  # right col split
    # Focus to the top-left to start navigating.
    Ressac.cmd_focus!(app.workspaces, :left)
    Ressac.cmd_focus!(app.workspaces, :up)
    Tachikoma.view(app, frame)
    ws = Ressac.current_workspace(app.workspaces)
    start = ws.focused_pane
    # Navigate right via C-w l
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w'))
    Tachikoma.update!(app, Tachikoma.KeyEvent('l'))
    @test ws.focused_pane != start
    # And back via C-w h
    Tachikoma.update!(app, Tachikoma.KeyEvent('h'))
    @test ws.focused_pane == start
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
end

@testset "C-w c closes the focused pane" begin
    app, frame = _new_app()
    Ressac._active_editor(app).mode = :normal
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w'))
    Tachikoma.update!(app, Tachikoma.KeyEvent('v'))
    ws = Ressac.current_workspace(app.workspaces)
    @test length(collect(Ressac._all_leaves(ws.tree))) == 2
    Tachikoma.update!(app, Tachikoma.KeyEvent('c'))
    @test length(collect(Ressac._all_leaves(ws.tree))) == 1
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
end

# ── Workspace switching ─────────────────────────────────────────────

@testset "C-w c refuses to close the last leaf (no empty workspace)" begin
    app, frame = _new_app()
    Ressac._active_editor(app).mode = :normal
    ws = Ressac.current_workspace(app.workspaces)
    @test length(collect(Ressac._all_leaves(ws.tree))) == 1
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w'))
    Tachikoma.update!(app, Tachikoma.KeyEvent('c'))
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    @test length(collect(Ressac._all_leaves(ws.tree))) == 1
end

@testset ":vsplit <kind> creates the right pane type" begin
    app, _ = _new_app()
    # Drive an ex command end-to-end via the command-mode editor flow.
    _exec_ex_command!(app, "vsplit log")
    ws = Ressac.current_workspace(app.workspaces)
    leaves = collect(Ressac._all_leaves(ws.tree))
    @test length(leaves) == 2
    @test any(l -> any(t -> t isa Ressac.LogPane, l.tabs), leaves)

    _exec_ex_command!(app, "hsplit doc")
    leaves = collect(Ressac._all_leaves(ws.tree))
    @test length(leaves) == 3
    @test any(l -> any(t -> t isa Ressac.DocPane, l.tabs), leaves)
end

@testset ":pclose removes a pane the player split" begin
    app, _ = _new_app()
    _exec_ex_command!(app, "vsplit log")
    ws = Ressac.current_workspace(app.workspaces)
    @test length(collect(Ressac._all_leaves(ws.tree))) == 2
    _exec_ex_command!(app, "pclose")
    @test length(collect(Ressac._all_leaves(ws.tree))) == 1

end

@testset ":float lifts pane out of tree; :tile drops it back" begin
    app, _ = _new_app()
    _exec_ex_command!(app, "vsplit log")
    ws = Ressac.current_workspace(app.workspaces)
    @test isempty(ws.floats)
    @test length(collect(Ressac._all_leaves(ws.tree))) == 2
    _exec_ex_command!(app, "float")
    @test length(ws.floats) == 1
    @test length(collect(Ressac._all_leaves(ws.tree))) == 1
    _exec_ex_command!(app, "tile")
    @test isempty(ws.floats)
    @test length(collect(Ressac._all_leaves(ws.tree))) == 2
end

# ── Mouse focus ─────────────────────────────────────────────────────

@testset "left-click on a non-focused pane changes focus" begin
    app, frame = _new_app()
    Ressac._active_editor(app).mode = :normal
    Ressac.cmd_vsplit!(app.workspaces, "log", Dict{String,Any}())
    Tachikoma.view(app, frame)   # populate _last_ws_area + rects
    ws = Ressac.current_workspace(app.workspaces)
    # After vsplit, focused = the new (log) leaf.
    log_leaf_id = ws.focused_pane
    # Click far left — that's inside the patterns leaf (column 1).
    evt = Tachikoma.MouseEvent(2, 10, Tachikoma.mouse_left,
                                Tachikoma.mouse_press, false, false, false)
    Tachikoma.update!(app, evt)
    @test ws.focused_pane != log_leaf_id
end

# ── Quit flow ───────────────────────────────────────────────────────

@testset ":q ferme une pane ; :qa quitte et sauve le layout" begin
    app, frame = _new_app()
    Ressac._active_editor(app).mode = :normal
    # Build a non-trivial tree so save_layout has something to write.
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w'))
    Tachikoma.update!(app, Tachikoma.KeyEvent('v'))
    Tachikoma.update!(app, Tachikoma.KeyEvent('s'))
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    # Le layout part dans le bac à sable (RESSAC_CONFIG_DIR, helpers.jl).
    @test startswith(Ressac._default_layout_path(), _TEST_SANDBOX)
    # :q ferme d'abord une pane (workspace multi-panes) ; :qa quitte et
    # sauve le layout.
    Tachikoma.update!(app, Tachikoma.KeyEvent(':'))
    Tachikoma.update!(app, Tachikoma.KeyEvent('q'))
    Tachikoma.update!(app, Tachikoma.KeyEvent(:enter))
    @test app.quit == false
    for c in ":qa"; Tachikoma.update!(app, Tachikoma.KeyEvent(c)); end
    Tachikoma.update!(app, Tachikoma.KeyEvent(:enter))
    @test app.quit == true
    @test isfile(Ressac._default_layout_path())
end

# ── Modal flows ─────────────────────────────────────────────────────

@testset "Esc closes any open modal back to :none" begin
    app, _ = _new_app()
    Ressac._active_editor(app).mode = :normal
    for kind in (:help, :browse, :synth_library, :snippets, :mixer)
        app.modal = kind
        Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
        @test app.modal === :none
    end
end

# ── Snippet panes (starter) ────────────────────────────────────────

@testset ":starter snippet with panes = [...] rebuilds workspace" begin
    app, _ = _new_app()
    Ressac._active_editor(app).mode = :normal
    # Synthesize a minimal snippet entry with panes and register it.
    name = "ui-integration-test-snip-$(rand(UInt32))"
    snip = Ressac.SnippetEntry(name, :starter, "test", Symbol[],
        :patterns, String[], String[],
        "@d1 :bd",
        Any[Dict("role" => "primary", "kind" => "editor",
                  "buffer_role" => "patterns"),
            Dict("role" => "side",    "kind" => "log",
                  "side" => "right", "size" => 0.3)],
        "test", "")
    Ressac.register_snippet!(snip)
    try
        Ressac._starter_command!(app, name)
        ws = Ressac.current_workspace(app.workspaces)
        leaves = collect(Ressac._all_leaves(ws.tree))
        @test length(leaves) == 2
        kinds = sort([typeof(l.tabs[1]) for l in leaves]; by = string)
        @test Ressac.EditorPane in kinds
        @test Ressac.LogPane    in kinds
        # Buffer text seeded from the snippet.
        @test occursin("@d1", Ressac.TK.text(Ressac._active_editor(app)))
    finally
        delete!(Ressac._SNIPPETS, name)
    end
end

@testset ":starter block mode composes panes onto current tree" begin
    app, _ = _new_app()
    Ressac._active_editor(app).mode = :normal
    # Start with a pre-existing split so we can check that block
    # mode does NOT rebuild the tree (unlike :starter).
    Ressac.cmd_vsplit!(app.workspaces, "editor", Dict{String,Any}())
    pre_leaves = length(collect(Ressac._all_leaves(
        Ressac.current_workspace(app.workspaces).tree)))
    name = "ui-it-block-snip-$(rand(UInt32))"
    snip = Ressac.SnippetEntry(name, :block, "test", Symbol[],
        :patterns, String[], String[],
        "// block body",
        Any[Dict("role" => "primary", "kind" => "editor",
                  "buffer_role" => "patterns"),
            Dict("role" => "side", "kind" => "doc",
                  "ref" => "gain", "side" => "right", "size" => 0.3)],
        "test", "")
    Ressac.register_snippet!(snip)
    try
        Ressac.apply_snippet_panes!(app.workspaces, snip.panes, snip.mode;
                                     snippet_name = snip.name)
        ws = Ressac.current_workspace(app.workspaces)
        leaves = collect(Ressac._all_leaves(ws.tree))
        # Block adds side panes — primary is not re-installed.
        @test length(leaves) == pre_leaves + 1
        @test any(l -> any(t -> t isa Ressac.DocPane, l.tabs), leaves)
    finally
        delete!(Ressac._SNIPPETS, name)
    end
end

# ── Multi-tabs in a single pane ────────────────────────────────────

@testset "EditorPane with multiple tabs renders strip + isolates buffers" begin
    app, _ = _new_app()
    ws = Ressac.current_workspace(app.workspaces)
    ep = ws.tree.tabs[1]
    @test ep isa Ressac.EditorPane
    push!(ep.tabs, Ressac.EditorBuffer(role = :synth, name = "wob1"))
    @test length(ep.tabs) == 2
    # Render — first inner row should show both tab names.
    tb = Tachikoma.TestBackend(60, 12)
    Ressac.render!(ep, Tachikoma.Rect(1, 1, 60, 12), tb.buf)
    tab_row = Tachikoma.row_text(tb, 2)
    @test occursin("main", tab_row)
    @test occursin("wob1", tab_row)
    # The two tab buffers are independent text containers.
    Ressac.TK.set_text!(ep.tabs[1].code_editor, "tab1 only")
    Ressac.TK.set_text!(ep.tabs[2].code_editor, "tab2 only")
    @test Ressac.TK.text(ep.tabs[1].code_editor) == "tab1 only"
    @test Ressac.TK.text(ep.tabs[2].code_editor) == "tab2 only"
end

# ── Per-pane render content ────────────────────────────────────────

@testset "LogPane render shows the app's log lines + j/k scroll" begin
    app, _ = _new_app()
    # _APP_LOG[] est rebranché sur app.logs à chaque update! : on remplit app.logs
    empty!(app.logs); append!(app.logs, ["[INFO] line A", "[INFO] line B", "[INFO] line C"])
    Ressac.cmd_vsplit!(app.workspaces, "log", Dict{String,Any}())
    ws = Ressac.current_workspace(app.workspaces)
    log_leaf = Ressac._find_leaf_by_id(ws.tree, ws.focused_pane)
    log_pane = log_leaf.tabs[1]
    @test log_pane isa Ressac.LogPane
    tb = Tachikoma.TestBackend(60, 8)
    Ressac.render!(log_pane, Tachikoma.Rect(1, 1, 60, 8), tb.buf)
    body = join((Tachikoma.row_text(tb, y) for y in 2:7), '\n')
    @test occursin("line C", body)
    # 'k' scrolls older entries into view (once the log is taller than the pane)
    for i in 1:20; Ressac._push_app_log!(app, "[INFO] ligne $i"); end
    Ressac.render!(log_pane, Tachikoma.Rect(1, 1, 60, 8), tb.buf)
    Tachikoma.update!(app, Tachikoma.KeyEvent('k'))
    @test log_pane.pane.offset == Ressac._scroll_last(log_pane.pane) - 1 && !log_pane.pane.following
end

@testset "DocPane render shows the entry body" begin
    app, _ = _new_app()
    # Register a DocEntry inline so the test owns its data.
    name = "ui-it-doc-$(rand(UInt32))"
    Ressac.register_doc!(Ressac.DocEntry(
        name, "short of $name", Symbol[], Symbol[],
        ["example1", "example2"], String[],
        "Long body for the integration test.",
        "test", ""))
    try
        Ressac.cmd_vsplit!(app.workspaces, "doc",
                           Dict{String,Any}("ref" => name))
        ws = Ressac.current_workspace(app.workspaces)
        leaf = Ressac._find_leaf_by_id(ws.tree, ws.focused_pane)
        dp = leaf.tabs[1]
        @test dp isa Ressac.DocPane
        @test dp.name == name
        tb = Tachikoma.TestBackend(60, 12)
        Ressac.render!(dp, Tachikoma.Rect(1, 1, 60, 12), tb.buf)
        body = join((Tachikoma.row_text(tb, y) for y in 2:11), '\n')
        @test occursin("short of", body)
        @test occursin("example1", body)
        @test occursin("Long body", body)
    finally
        delete!(Ressac._DOCS, name)
    end
end

@testset "ScopePane render shows subtype-specific waiting hint" begin
    app, _ = _new_app()
    # Empty _APP_SCOPE_DATA → render hits the "waiting for audio" path.
    Ressac.cmd_vsplit!(app.workspaces, "scope",
                       Dict{String,Any}("target" => "wave"))
    ws = Ressac.current_workspace(app.workspaces)
    leaf = Ressac._find_leaf_by_id(ws.tree, ws.focused_pane)
    sp = leaf.tabs[1]
    @test sp isa Ressac.ScopePane
    @test sp.subtype === :wave
    tb = Tachikoma.TestBackend(60, 6)
    Ressac.render!(sp, Tachikoma.Rect(1, 1, 60, 6), tb.buf)
    body = join((Tachikoma.row_text(tb, y) for y in 2:5), '\n')
    @test occursin("waiting", body) || occursin("SCOPE", Tachikoma.row_text(tb, 1))
end

# ── Vim modal — visual / yank / delete ─────────────────────────────

@testset "i + text + Esc lands text in Ressac._active_editor(m)" begin
    app, _ = _new_app()
    Ressac.TK.set_text!(Ressac._active_editor(app), "")
    Tachikoma.update!(app, Tachikoma.KeyEvent('i'))
    _type!(app, "hello world")
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    @test occursin("hello world", Ressac.TK.text(Ressac._active_editor(app)))
    @test Ressac._active_editor(app).mode === :normal
end

@testset "V + j + y yanks line range" begin
    app, _ = _new_app()
    Ressac.TK.set_text!(Ressac._active_editor(app), "line1\nline2\nline3")
    Ressac._active_editor(app).cursor_row = 1
    Ressac._active_editor(app).cursor_col = 0
    Tachikoma.update!(app, Tachikoma.KeyEvent('V'))   # visual line
    Tachikoma.update!(app, Tachikoma.KeyEvent('j'))   # extend down
    Tachikoma.update!(app, Tachikoma.KeyEvent('y'))   # yank
    # Visual mode should have exited and yank buffer populated.
    @test Ressac._active_editor(app).mode === :normal
end

# ── Eval routing (stubs — confirm dispatch path, not real eval) ─────

@testset "Pressing e on patterns pane in :normal triggers eval path" begin
    app, _ = _new_app()
    Ressac._active_editor(app).mode = :normal
    # The current eval bridges are no-op stubs but the dispatch
    # should still consume the key without crashing.
    Tachikoma.update!(app, Tachikoma.KeyEvent('e'))
    # Patterns leaf still owns focus; no exception thrown.
    @test Ressac.current_workspace(app.workspaces).focused_pane ==
          _patterns_leaf_id(app)
end

@testset "T on a focused synth pane routes to the SC eval path" begin
    app, frame = _new_app()
    Ressac._active_editor(app).mode = :normal
    Ressac.cmd_vsplit!(app.workspaces, "editor",
                       Dict{String,Any}("buffer_role" => "synth",
                                         "name" => "wob1"))
    Tachikoma.view(app, frame)
    ws = Ressac.current_workspace(app.workspaces)
    leaf = Ressac._find_leaf_by_id(ws.tree, ws.focused_pane)
    @test leaf.tabs[1].tabs[1].role === :synth
    leaf.tabs[1].tabs[1].code_editor.mode = :normal
    # La pane synth est une pane éditeur : le routage la laisse au flux
    # éditeur (:editor), où le binding :synth « t/T/Space » tire le synth
    # via _fire_t_with_accel! (no-op sans scheduler, mais il arme l'horloge
    # de rafale) et consomme la touche (rien n'est tapé dans le buffer).
    @test Ressac._route_key_to_focused_pane!(app, Tachikoma.KeyEvent('T')) === :editor
    before = Tachikoma.text(leaf.tabs[1].tabs[1].code_editor)
    Tachikoma.update!(app, Tachikoma.KeyEvent('T'))
    @test app.last_t_fire > 0
    @test Tachikoma.text(leaf.tabs[1].tabs[1].code_editor) == before
    # Touche maintenue → chemin « held » (répétition accélérée), pas de plantage.
    Tachikoma.update!(app, Tachikoma.KeyEvent(:char, 'T', Tachikoma.key_repeat))
    @test app.last_t_fire > 0
end

# ── Modal flows — navigation, not just close ───────────────────────

@testset "Modal :browse opens via the wiki/browse picker entry point" begin
    app, _ = _new_app()
    Ressac._active_editor(app).mode = :normal
    # The modal is opened by app code; set it directly to verify
    # Esc closes it. Real opener wiring is per-modal and tested in
    # each picker's own unit suite.
    app.modal = :browse
    @test app.modal === :browse
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    @test app.modal === :none
end

# ── Layout persistence e2e (round-trip via real keystrokes) ────────

@testset ":layout save/load preserves editor + synth content" begin
    app, frame = _new_app()
    Ressac.TK.set_text!(Ressac._active_editor(app),
        "@d1 p\"bd sn\"  # KEEPME")
    Ressac._open_synth_tab!(app, "wobx")
    Ressac.TK.set_text!(Ressac._current_synth_tab(app).code_editor,
        "@synth :wobx saw(:freq)  # SYNTHKEEP")
    path = tempname() * ".toml"
    try
        Ressac.save_layout(app.workspaces, path)
        wm2 = Ressac.WorkspaceManager()
        Ressac.load_layout!(wm2, path)
        texts = String[]
        for leaf in Ressac._all_leaves(Ressac.current_workspace(wm2).tree)
            for tab in leaf.tabs
                tab isa Ressac.EditorPane || continue
                for b in tab.tabs
                    push!(texts, Ressac.TK.text(b.code_editor))
                end
            end
        end
        @test any(t -> occursin("KEEPME", t), texts)
        @test any(t -> occursin("SYNTHKEEP", t), texts)
    finally
        rm(path; force = true)
    end
end

@testset ":layout save / load round-trip via keystrokes" begin
    app, frame = _new_app()
    Ressac._active_editor(app).mode = :normal
    _exec_ex_command!(app, "vsplit log")
    _exec_ex_command!(app, "vsplit doc")
    ws_before = Ressac.current_workspace(app.workspaces)
    n_before = length(collect(Ressac._all_leaves(ws_before.tree)))
    @test n_before == 3
    name = "ui-it-roundtrip-$(rand(UInt32))"
    _exec_ex_command!(app, "layout save $name")
    @test isfile(Ressac._named_layout_path(name))
    # Wipe and reload.
    empty!(app.workspaces.workspaces)
    app.workspaces.current_idx = 0
    Ressac._ensure_default_workspace!(app)
    _only_patterns!(app)
    @test length(collect(Ressac._all_leaves(
        Ressac.current_workspace(app.workspaces).tree))) == 1
    _exec_ex_command!(app, "layout load $name")
    ws_after = Ressac.current_workspace(app.workspaces)
    @test length(collect(Ressac._all_leaves(ws_after.tree))) == n_before
    rm(Ressac._named_layout_path(name); force = true)
end

@testset ":layout load <unknown> warns and stays on current layout" begin
    app, _ = _new_app()
    Ressac._active_editor(app).mode = :normal
    pre_workspaces = length(app.workspaces.workspaces)
    _exec_ex_command!(app, "layout load nonexistent-layout-zzz")
    # Warn-only — workspace state unchanged.
    @test length(app.workspaces.workspaces) == pre_workspaces
    @test any(l -> occursin("introuvable", l), app.logs)
end

# ── Edge cases ─────────────────────────────────────────────────────

@testset "View renders to a tiny rect without throwing" begin
    mock = MockOSCClient()
    sched = Ressac.Scheduler(mock; cps = 0.5)
    app = Ressac.RessacApp(; scheduler = sched)
    tb = Tachikoma.TestBackend(8, 6)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 8, 6),
                            Tachikoma.GraphicsRegion[],
                            Tachikoma.PixelSnapshot[])
    @test_nowarn Tachikoma.view(app, frame)
end

@testset ":tuning edo <N> registers a new EDO scale" begin
    app, _ = _new_app()
    pre = length(Ressac.list_scales())
    _exec_ex_command!(app, "tuning edo 19")
    @test :edo_19 in Ressac.list_scales()
    @test Ressac.lookup_scale(:edo_19).period_cents == 1200.0
    @test length(Ressac.lookup_scale(:edo_19).cents) == 19
    @test length(Ressac.list_scales()) >= pre + 1
end

@testset ":tuning ratios <r1> <r2> ... registers a just-intonation scale" begin
    app, _ = _new_app()
    _exec_ex_command!(app, "tuning ratios 1 9/8 5/4 4/3 3/2 5/3 15/8 2")
    name = :ratios_1_9o8_5o4_4o3_3o2_5o3_15o8_2
    @test name in Ressac.list_scales()
    s = Ressac.lookup_scale(name)
    # 7 step degrees within one octave
    @test length(s.cents) == 7
    @test s.period_cents ≈ 1200.0
end

@testset ":tuning bp registers Bohlen-Pierce lambda by default" begin
    app, _ = _new_app()
    _exec_ex_command!(app, "tuning bp")
    @test :bp_lambda in Ressac.list_scales()
    bp = Ressac.lookup_scale(:bp_lambda)
    @test bp.period_cents ≈ 1200 * log2(3) atol = 1e-6
end

@testset ":tuning bp <variant> picks the variant" begin
    app, _ = _new_app()
    _exec_ex_command!(app, "tuning bp dur")
    @test :bp_dur in Ressac.list_scales()
end

@testset ":tuning golden and :tuning fib and :tuning sb register" begin
    app, _ = _new_app()
    _exec_ex_command!(app, "tuning golden")
    _exec_ex_command!(app, "tuning fib 5")
    _exec_ex_command!(app, "tuning sb 3")
    @test :golden_12 in Ressac.list_scales()
    @test :fib_5 in Ressac.list_scales()
    @test :sb_3 in Ressac.list_scales()
end

@testset ":tuning cf <coeffs> registers a continued-fraction scale" begin
    app, _ = _new_app()
    _exec_ex_command!(app, "tuning cf 1 2 2 2")
    @test :cf_1_2_2_2 in Ressac.list_scales()
end

@testset ":scale ouvre la liste des gammes dans un modal défilable" begin
    app, _ = _new_app()
    _exec_ex_command!(app, "scale list")
    @test app.modal === :listing
    @test app.listing_title == "GAMMES"
    @test any(l -> occursin("major", l) || occursin("minor", l), app.listing_lines)
    @test any(l -> occursin("degrés", l), app.listing_lines)
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    @test app.modal === :none
    # `:scale` tout court ouvre la même liste
    _exec_ex_command!(app, "scale")
    @test app.modal === :listing && !isempty(app.listing_lines)
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    # les autres listes passent par le même modal
    for (cmd, title) in (("samples", "SAMPLES"), ("synths", "SYNTHS"),
                         ("instruments", "INSTRUMENTS"), ("chords", "ACCORDS"),
                         ("themes", "THÈMES"))
        _exec_ex_command!(app, cmd)
        @test app.modal === :listing
        @test app.listing_title == title
        Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    end
    # mise en colonnes : cent noms courts tiennent en quelques lignes
    cols = Ressac._columnise(["n$i" for i in 1:100]; width = 96)
    @test length(cols) < 20 && occursin("n1", cols[1])
    @test isempty(Ressac._columnise(String[]))
end

@testset "Snippet panes with unknown kind warns + skips that side" begin
    app, _ = _new_app()
    name = "ui-it-badpanes-$(rand(UInt32))"
    snip = Ressac.SnippetEntry(name, :starter, "", Symbol[],
        :patterns, String[], String[],
        "@d1 :bd",
        Any[Dict("role" => "primary", "kind" => "editor"),
            Dict("role" => "side", "kind" => "totally-fake-zzz")],
        "test", "")
    Ressac.register_snippet!(snip)
    try
        @test_logs (:warn,) Ressac._starter_command!(app, name)
        # Primary still installed even though side was skipped.
        @test occursin("@d1", Ressac.TK.text(Ressac._active_editor(app)))
    finally
        delete!(Ressac._SNIPPETS, name)
    end
end

@testset "Ctrl-1 on a 1-workspace app is a no-op (no crash)" begin
    app, _ = _new_app()
    @test app.workspaces.current_idx == 1
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, '5'))   # idx 5 doesn't exist
    @test app.workspaces.current_idx == 1                    # still safe
end

# ── Synth tabs ─────────────────────────────────────────────────────

# Synth panes are workspace EditorPanes (role=:synth) now —
# inspect via Ressac._all_synth_buffers.
_synth_names(app) = [b.name for (_, b) in Ressac._all_synth_buffers(app)]

@testset ":synth <name> opens a synth pane in the workspace" begin
    app, _ = _new_app()
    @test isempty(_synth_names(app))
    _exec_ex_command!(app, "synth wob")                      # :synth emmène dans DESIGN : sketch + wob
    @test app.volet === :son
    @test "wob" in _synth_names(app)
end

@testset ":synth + :tabnext + :close + :back lifecycle" begin
    app, frame = _new_app()
    _exec_ex_command!(app, "synth one")
    _exec_ex_command!(app, "synth two")
    @test Set(_synth_names(app)) == Set(["sketch", "one", "two"])
    ws = Ressac.current_workspace(app.workspaces)
    # Focused on the most-recently-opened synth pane.
    @test Ressac._focused_role(app) === :synth
    # tabprev / tabnext cycle focus between the two synth panes.
    _exec_ex_command!(app, "tabprev")
    @test Ressac._focused_role(app) === :synth
    _exec_ex_command!(app, "tabnext")
    @test Ressac._focused_role(app) === :synth
    _exec_ex_command!(app, "close")     # close the current synth tab
    @test length(_synth_names(app)) == 2
    _exec_ex_command!(app, "back")      # le volet se ferme, les sons restent ouverts derrière
    @test app.volet === :fiche && Ressac._focused_role(app) === :patterns
    @test isempty(_synth_names(app))
end

# ── Modal flows — navigation, not just open/close ──────────────────

@testset ":browse opens browser modal" begin
    app, _ = _new_app()
    _exec_ex_command!(app, "browse")
    @test app.modal === :browse
end

@testset ":snippets opens picker; Esc closes" begin
    app, _ = _new_app()
    _exec_ex_command!(app, "snippets")
    @test app.modal === :snippets
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    @test app.modal === :none
end

@testset ":synthlib + :mixer open their modals (Esc closes)" begin
    app, _ = _new_app()
    for (cmd, kind) in (("synthlib", :synth_library),
                        ("mixer", :mixer))
        _exec_ex_command!(app, cmd)
        @test app.modal === kind
        Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
        @test app.modal === :none
    end
    # :wiki ouvre une pane (plus un modal) : jamais de modal, pas de crash
    # même si docs/wiki/ n'est pas accessible depuis pwd().
    _exec_ex_command!(app, "wiki")
    @test app.modal === :none
end

@testset ":guide + :tutorial set modal to help/tutorial" begin
    app, _ = _new_app()
    _exec_ex_command!(app, "guide")
    @test app.modal === :help
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    _exec_ex_command!(app, "tutorial")
    @test app.modal === :none && Ressac._find_pane(app, Ressac.TutorialPane) !== nothing
end

# ── Scope ex commands ──────────────────────────────────────────────

@testset ":scope <type> flips the scope global type" begin
    app, _ = _new_app()
    # _app_scope_set! gates non-:off type flips on the presence of a
    # live scheduler. Install ours into _LIVE_SCHEDULER[] for the
    # duration of the test, then restore.
    prev_sched = Ressac._LIVE_SCHEDULER[]
    Ressac._LIVE_SCHEDULER[] = app.scheduler
    Ressac._APP_SCOPE_TYPE[] = :off
    try
        @test Ressac._APP_SCOPE_TYPE[] === :off
        _exec_ex_command!(app, "scope wave")
        @test Ressac._APP_SCOPE_TYPE[] === :wave
        _exec_ex_command!(app, "scope amp")
        @test Ressac._APP_SCOPE_TYPE[] === :amp
        _exec_ex_command!(app, "scope")
        @test Ressac._APP_SCOPE_TYPE[] === :off
    finally
        Ressac._LIVE_SCHEDULER[] = prev_sched
    end
end

# ── hush / panic / recording / tap / piano state machines ─────────

@testset ":hush + :panic flip silence flags without crash" begin
    app, _ = _new_app()
    # Sans session live : rien à arrêter, pas d'exception.
    _exec_ex_command!(app, "hush"); @test !app.quit
    Ressac._LIVE_SCHEDULER[] = app.scheduler
    try
        set_pattern!(app.scheduler, :d1, pure(:bd))
        @test any(l -> occursin("hush", l), _cmd_logs(app, "hush"))
        @test isempty(Ressac.pattern_keys(app.scheduler))
        set_pattern!(app.scheduler, :d1, pure(:bd))
        @test any(l -> occursin("PANIC", l), _cmd_logs(app, "panic"))
        @test isempty(Ressac.pattern_keys(app.scheduler))
        @test any(b -> occursin("/ressac/panic", String(copy(b))), app.scheduler.osc.sent)
    finally
        Ressac._LIVE_SCHEDULER[] = nothing
    end
end

@testset ":explain opens a scrollable explainer modal" begin
    @testset ":explain <name> on a missing synth → graceful modal" begin
        app, _ = _new_app()
        Ressac._handle_ex_command!(app, "explain __does_not_exist__")
        @test app.modal === :explain
        @test !isempty(app.explain_lines)
        Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))   # Esc ferme
        @test app.modal === :none
    end

    @testset ":explain (no arg) explains the focused DSL buffer" begin
        app, _ = _new_app()
        ed = Ressac._active_editor(app)
        ed.mode = :normal
        Tachikoma.set_text!(ed, "@synth :b (freq=100, sustain=0.5) begin\n" *
                                "  n1 = ugen(:Saw, :freq)\n" *
                                "  ugen(:RLPF, n1, 300, 0.2)\nend\n")
        Ressac._handle_ex_command!(app, "explain")
        # un @synth dans la pane patterns de PLAY : :explain vit dans DESIGN, où la
        # DOC prend l'explication — le buffer de PLAY n'est pas un synth, donc
        # l'explication concerne le sketch de DESIGN
        @test app.volet === :son
        parts = Ressac._synth_workspace_parts(app)
        @test parts !== nothing && parts[2].mode === :explain
    end
end

@testset "! is a GLOBAL panic except while typing" begin
    _npanic(app) = count(l -> occursin("PANIC", l), app.logs)

    @testset "fires from the editor in normal mode" begin
        app, _ = _new_app()
        Ressac._active_editor(app).mode = :normal
        n0 = _npanic(app)
        Tachikoma.update!(app, Tachikoma.KeyEvent('!'))
        @test _npanic(app) == n0 + 1
    end

    @testset "fires from inside a modal (synth library)" begin
        app, _ = _new_app()
        Ressac._active_editor(app).mode = :normal
        app.modal = :synth_library
        Tachikoma.update!(app, Tachikoma.KeyEvent('!'))
        @test _npanic(app) >= 1
    end

    @testset "fires from a non-editor pane (explorer focused)" begin
        app, _ = _new_app()
        Ressac.cmd_vsplit!(app.workspaces, "explorer", Dict{String,Any}("rng" => 2))
        n0 = _npanic(app)
        Tachikoma.update!(app, Tachikoma.KeyEvent('!'))
        @test _npanic(app) == n0 + 1
    end

    @testset "does NOT fire in insert mode (typed as a char)" begin
        app, _ = _new_app()
        ed = Ressac._active_editor(app)
        ed.mode = :insert
        Tachikoma.set_text!(ed, "")
        n0 = _npanic(app)
        Tachikoma.update!(app, Tachikoma.KeyEvent('!'))
        @test _npanic(app) == n0                       # pas de panic
        @test occursin("!", Tachikoma.text(ed))        # tapé dans le buffer
    end

    @testset "does NOT fire while the command line is active" begin
        app, _ = _new_app()
        Ressac._active_editor(app).mode = :normal
        Tachikoma.update!(app, Tachikoma.KeyEvent(':'))   # ouvre la barre de commande
        n0 = _npanic(app)
        Tachikoma.update!(app, Tachikoma.KeyEvent('!'))
        @test _npanic(app) == n0                       # ! va dans la commande
    end
end

@testset ":rec toggles m.recording (smoke — no actual SC)" begin
    app, _ = _new_app()
    # Without a live SC session, :rec start logs an error and bails;
    # we still want the path to execute without raising.
    pre = app.recording
    _exec_ex_command!(app, "rec")
    # State may not change (no live session) but must not crash.
    @test app.recording == pre
end

@testset ":tap enters tap-recording mode" begin
    app, _ = _new_app()
    @test app.tap_recording == false
    _exec_ex_command!(app, "tap")
    @test app.tap_recording == true
    # Esc cancels tap recording without affecting anything else.
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    @test app.tap_recording == false
end

@testset ":piano enters piano mode; Esc exits" begin
    app, _ = _new_app()
    @test app.piano_active == false
    _exec_ex_command!(app, "piano")
    @test app.piano_active == true
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    @test app.piano_active == false
end

@testset ":piano octave shift via [ and ]" begin
    app, _ = _new_app()
    _exec_ex_command!(app, "piano")
    pre = app.piano_octave
    Tachikoma.update!(app, Tachikoma.KeyEvent(']'))
    @test app.piano_octave == pre + 1
    Tachikoma.update!(app, Tachikoma.KeyEvent('['))
    @test app.piano_octave == pre
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
end

# ── Vim motions, visual, dot repeat ────────────────────────────────

@testset "x deletes one char at cursor (normal mode)" begin
    app, _ = _new_app()
    Ressac.TK.set_text!(Ressac._active_editor(app), "hello")
    Ressac._active_editor(app).cursor_row = 1
    Ressac._active_editor(app).cursor_col = 0
    Ressac._active_editor(app).mode = :normal
    Tachikoma.update!(app, Tachikoma.KeyEvent('x'))
    @test Ressac.TK.text(Ressac._active_editor(app)) == "ello"
end

@testset "dd deletes a whole line" begin
    app, _ = _new_app()
    Ressac.TK.set_text!(Ressac._active_editor(app), "line1\nline2\nline3")
    Ressac._active_editor(app).cursor_row = 2
    Ressac._active_editor(app).cursor_col = 0
    Ressac._active_editor(app).mode = :normal
    Tachikoma.update!(app, Tachikoma.KeyEvent('d'))
    Tachikoma.update!(app, Tachikoma.KeyEvent('d'))
    @test Ressac.TK.text(Ressac._active_editor(app)) == "line1\nline3"
end

@testset "yy + p duplicates the current line" begin
    app, _ = _new_app()
    Ressac.TK.set_text!(Ressac._active_editor(app), "alpha\nbeta")
    Ressac._active_editor(app).cursor_row = 1
    Ressac._active_editor(app).cursor_col = 0
    Ressac._active_editor(app).mode = :normal
    Tachikoma.update!(app, Tachikoma.KeyEvent('y'))
    Tachikoma.update!(app, Tachikoma.KeyEvent('y'))
    Tachikoma.update!(app, Tachikoma.KeyEvent('p'))
    @test occursin("alpha\nalpha", Ressac.TK.text(Ressac._active_editor(app)))
end

@testset "u undoes the last text mutation" begin
    app, _ = _new_app()
    Ressac.TK.set_text!(Ressac._active_editor(app), "original")
    Ressac._active_editor(app).cursor_row = 1
    Ressac._active_editor(app).cursor_col = 0
    Ressac._active_editor(app).mode = :normal
    Tachikoma.update!(app, Tachikoma.KeyEvent('x'))           # delete 'o'
    @test Ressac.TK.text(Ressac._active_editor(app)) == "riginal"
    Tachikoma.update!(app, Tachikoma.KeyEvent('u'))
    @test Ressac.TK.text(Ressac._active_editor(app)) == "original"
end

# ── Starter prefix / ambiguity ─────────────────────────────────────

@testset ":starter accepts a unique prefix match" begin
    app, _ = _new_app()
    name = "ui-it-starter-$(rand(UInt32))"
    snip = Ressac.SnippetEntry(name, :starter, "", Symbol[],
        :patterns, String[], String[],
        "@d1 :bd",
        Any[],   # no panes
        "test", "")
    Ressac.register_snippet!(snip)
    try
        # Use just the first 10 chars of `name` (unique prefix).
        Ressac._starter_command!(app, first(name, 10))
        @test occursin("@d1", Ressac.TK.text(Ressac._active_editor(app)))
    finally
        delete!(Ressac._SNIPPETS, name)
    end
end

@testset ":starter rejects an ambiguous prefix" begin
    app, _ = _new_app()
    name_a = "ui-it-amb-aaaa-$(rand(UInt32))"
    name_b = "ui-it-amb-bbbb-$(rand(UInt32))"
    for nm in (name_a, name_b)
        Ressac.register_snippet!(Ressac.SnippetEntry(nm, :starter, "",
            Symbol[], :patterns, String[], String[],
            "// dup", Any[], "test", ""))
    end
    try
        Ressac.TK.set_text!(Ressac._active_editor(app), "untouched")
        Ressac._starter_command!(app, "ui-it-amb")
        # Editor content unchanged because the prefix was ambiguous.
        @test Ressac.TK.text(Ressac._active_editor(app)) == "untouched"
        @test any(l -> occursin("ambigu", l), app.logs)
    finally
        delete!(Ressac._SNIPPETS, name_a)
        delete!(Ressac._SNIPPETS, name_b)
    end
end

# ── Session save / load ────────────────────────────────────────────

# ── Mouse wheel ────────────────────────────────────────────────────

@testset "wheel up on log area scrolls the chrome log offset" begin
    app, frame = _new_app()
    # The chrome log tail is at the bottom — bump a few entries so
    # there's something to scroll past.
    for i in 1:30
        Ressac._push_app_log!(app, "[INFO] entry #$i")
    end
    app.log_tail_rows = 10       # le journal déplié : de quoi faire défiler
    Tachikoma.view(app, frame)   # populate m.layout_logs
    @test app.log_view.following
    if app._last_log_rect !== nothing
        x = app._last_log_rect.x + 2
        y = app._last_log_rect.y + 2
        wheel = Tachikoma.MouseEvent(x, y, Tachikoma.mouse_scroll_up,
                                      Tachikoma.mouse_press, false, false, false)
        Tachikoma.update!(app, wheel)
        @test !app.log_view.following && app.log_view.offset < Ressac._scroll_last(app.log_view)
    else
        # Sans journal dans le chrome, rien à faire défiler : on vérifie
        # que c'est bien le cas, pas que le test « passe ».
        @test Ressac._global_log_tail_height(app) == 0
    end
end

# ── Pattern shortcuts (:sg, :sn etc.) ──────────────────────────────

@testset ":sg<n> shortcut sets gain via SHORTCUT_RX" begin
    app, _ = _new_app()
    _set_buffer!(app, "@d1 \"bd*4\"")
    logs = _cmd_logs(app, "sg0.5")
    @test _buffer_text(app) == "@d1 \"bd*4\" |> gain(0.5)"
    @test any(l -> occursin("raccourci → |> gain(0.5)", l), logs)
end

# ── Logging-side behaviors ─────────────────────────────────────────

@testset ":copylogs exports the log lines without crashing" begin
    app, _ = _new_app()
    Ressac._push_app_log!(app, "[INFO] hello copylog")
    pre = length(app.logs)
    _exec_ex_command!(app, "copylogs")
    # Either it added a log entry confirming the copy, or it was a
    # no-op outside an interactive terminal — must not crash.
    @test length(app.logs) >= pre
end

@testset ":keydebug toggles the keydebug flag" begin
    app, _ = _new_app()
    pre = app.keydebug
    _exec_ex_command!(app, "keydebug")
    @test app.keydebug != pre
    _exec_ex_command!(app, "keydebug")
    @test app.keydebug == pre
end

# ── Aliases ────────────────────────────────────────────────────────

@testset ":alias <new> <existing> registers an alias" begin
    app, _ = _new_app()
    # Use an alias name that doesn't collide with anything builtin.
    alias = "uiit$(rand(UInt16))"
    _exec_ex_command!(app, "alias $alias bd")
    @test any(l -> occursin("alias", l) || occursin(alias, l), app.logs)
end

@testset ":aliases lists registered aliases" begin
    app, _ = _new_app()
    with_clean_registries() do
        empty!(Ressac._SYNTH_ALIASES)
        @test any(l -> occursin("aucun alias", l), _cmd_logs(app, "aliases"))
        Ressac.register_synth_alias!(:wob, :wob1)
        @test any(l -> occursin("wob", l) && occursin("wob1", l), _cmd_logs(app, "aliases"))
    end
end

# ── :doc / :scope reservoir ────────────────────────────────────────

@testset ":doc <ref> logs an entry without crashing" begin
    app, _ = _new_app()
    name = "ui-it-doc-cmd-$(rand(UInt32))"
    Ressac.register_doc!(Ressac.DocEntry(name, "short", Symbol[],
        Symbol[], String[], String[], "", "test", ""))
    try
        _exec_ex_command!(app, "doc $name")
        @test any(l -> occursin(name, l) || occursin("doc", l), app.logs)
    finally
        delete!(Ressac._DOCS, name)
    end
end

# ── :w / save buffer to file ───────────────────────────────────────

@testset ":w <name> snapshots the buffer to sessions/<name>.txt" begin
    app, _ = _new_app()
    payload = "// :w smoke $(rand(UInt32))"
    Ressac.TK.set_text!(Ressac._active_editor(app), payload)
    name = "ui-it-w-$(rand(UInt32))"
    path = joinpath(pwd(), "sessions", "$name.txt")
    try
        _exec_ex_command!(app, "w $name")
        @test isfile(path)
        @test occursin(payload, read(path, String))
    finally
        rm(path; force = true)
    end
end

# ── :theme / :reload-config / :safety / :keydebug ──────────────────

@testset ":theme <name> doesn't crash on unknown themes" begin
    app, _ = _new_app()
    @test any(l -> startswith(l, "[ERROR]") || startswith(l, "[WARN]"), _cmd_logs(app, "theme totally-unknown"))
    @test any(l -> occursin("thème « inconnu » introuvable", l), _cmd_logs(app, "theme inconnu"))
    @test !app.quit
end

@testset ":safety on/off toggles a flag" begin
    app, _ = _new_app()
    _with_test_scheduler() do mock, sched
        @test any(l -> occursin("safety OFF", l), _cmd_logs(app, "safety off"))
        @test any(l -> occursin("safety ON", l), _cmd_logs(app, "safety on"))
        @test count(b -> occursin("/ressac/safety", String(copy(b))), mock.sent) == 2
    end
end

@testset ":reload-config triggers config reload path" begin
    app, _ = _new_app()
    @test any(l -> occursin("config rechargée", l), _cmd_logs(app, "reload-config"))
end

# ── :pause and resumption ──────────────────────────────────────────

@testset ":pause flips m.paused" begin
    app, _ = _new_app()
    _exec_ex_command!(app, "pause")
    @test app.paused == true
    # Resume by sending any key — update! flips paused=false.
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    @test app.paused == false
end

# ── :audio-in start / stop ────────────────────────────────────────

@testset ":audio-in start/stop don't crash without a live session" begin
    app, _ = _new_app()
    @test any(l -> occursin(":audio-in start — pas de session live", l), _cmd_logs(app, "audio-in start"))
    @test any(l -> occursin(":audio-in stop — pas de session live", l), _cmd_logs(app, "audio-in stop"))
end

# ── Scope variants ─────────────────────────────────────────────────

@testset ":scope reservoir <name> sets reservoir scope state" begin
    app, _ = _new_app()
    @test any(l -> occursin("« testres » n'est pas défini dans Main", l),
              _cmd_logs(app, "scope reservoir testres"))
end

# ── Ex command history navigation ──────────────────────────────────

@testset "Up arrow in CommandLine pulls last command from history" begin
    app, _ = _new_app()
    Ressac._active_editor(app).mode = :normal
    _exec_ex_command!(app, "hush")          # populates history
    Tachikoma.update!(app, Tachikoma.KeyEvent(':'))
    @test app.command_line.mode === :command
    Tachikoma.update!(app, Tachikoma.KeyEvent(:up))
    @test Ressac.current_text(app.command_line) == "hush"
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    @test app.command_line.mode === :idle
end

@testset "Tab in CommandLine cycles completion candidates" begin
    app, _ = _new_app()
    Ressac._active_editor(app).mode = :normal
    Tachikoma.update!(app, Tachikoma.KeyEvent(':'))
    _type!(app, "hus")
    Tachikoma.update!(app, Tachikoma.KeyEvent(:tab))
    # First Tab should pull in a match — "hush" is in the literal verbs.
    @test occursin("hush", Ressac.current_text(app.command_line))
    @test Ressac.completion_active(app.command_line)
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
end

# ── Mouse click positions the cursor in the patterns editor ────────

@testset "left-click on patterns area moves the cursor there" begin
    app, frame = _new_app()
    Ressac._active_editor(app).mode = :normal
    Ressac.TK.set_text!(Ressac._active_editor(app),
        "abcdefghij\n" * "ABCDEFGHIJ\n" * "0123456789")
    Tachikoma.view(app, frame)
    @test Ressac._focused_editor_rect(app) !== nothing
    # Click somewhere comfortably inside the patterns inner area.
    rect = Ressac._focused_editor_rect(app)
    target_y = rect.y + 1
    target_x = rect.x + 3
    evt = Tachikoma.MouseEvent(target_x, target_y,
        Tachikoma.mouse_left, Tachikoma.mouse_press,
        false, false, false)
    Tachikoma.update!(app, evt)
    @test Ressac._focused_role(app) === :patterns
end

# ── Ctrl-f (floats) et la recherche `/` ────────────────────────────

@testset "Ctrl-f montre / cache les floats, comme le registre le dit" begin
    app, _ = _new_app()
    Ressac._active_editor(app).mode = :normal
    @test Ressac.lookup(:global, "Ctrl-f"; target = app) !== nothing
    for c in ('f', 'F')                       # certains terminaux envoient la majuscule
        before = app.floats_hidden
        Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, c))
        @test app.floats_hidden == !before
        @test Ressac._active_editor(app).mode === :normal
    end
end

@testset "/texte cherche dans l'éditeur ; n et N parcourent les occurrences" begin
    app, _ = _new_app()
    ed = _set_buffer!(app, "@d1 \"bd hh\"\n@d2 \"hh*8\"\n@d3 \"cp\"")
    Tachikoma.update!(app, Tachikoma.KeyEvent('/'))
    @test Ressac.is_active(app.command_line)
    _type!(app, "hh")
    Tachikoma.update!(app, Tachikoma.KeyEvent(:enter))
    @test length(ed.search_matches) == 2
    @test (ed.cursor_row, ed.cursor_col) == (1, 8)
    @test any(l -> occursin("/hh — 1/2", l), app.logs)
    Tachikoma.update!(app, Tachikoma.KeyEvent('n'))
    @test (ed.cursor_row, ed.cursor_col) == (2, 5)
    Tachikoma.update!(app, Tachikoma.KeyEvent('n'))
    @test (ed.cursor_row, ed.cursor_col) == (1, 8)                 # boucle
    Tachikoma.update!(app, Tachikoma.KeyEvent('N'))
    @test (ed.cursor_row, ed.cursor_col) == (2, 5)
    Ressac._ex_search!(app, "nexistepas")
    @test isempty(ed.search_matches) && any(l -> occursin("/nexistepas — introuvable", l), app.logs)
    @test (ed.cursor_row, ed.cursor_col) == (2, 5)                 # le curseur ne bouge pas
    Ressac._ex_search!(app, "")
    @test isempty(ed.search_query)
end

# ── Word motions: dw / cw / w / b ──────────────────────────────────

@testset "dw deletes word forward" begin
    app, _ = _new_app()
    Ressac.TK.set_text!(Ressac._active_editor(app), "alpha beta gamma")
    Ressac._active_editor(app).cursor_row = 1
    Ressac._active_editor(app).cursor_col = 0
    Ressac._active_editor(app).mode = :normal
    Tachikoma.update!(app, Tachikoma.KeyEvent('d'))
    Tachikoma.update!(app, Tachikoma.KeyEvent('w'))
    @test occursin("beta gamma", Ressac.TK.text(Ressac._active_editor(app)))
    @test !startswith(Ressac.TK.text(Ressac._active_editor(app)), "alpha")
end

@testset "w moves cursor to start of next word" begin
    app, _ = _new_app()
    Ressac.TK.set_text!(Ressac._active_editor(app), "alpha beta")
    Ressac._active_editor(app).cursor_row = 1
    Ressac._active_editor(app).cursor_col = 0
    Ressac._active_editor(app).mode = :normal
    Tachikoma.update!(app, Tachikoma.KeyEvent('w'))
    @test Ressac._active_editor(app).cursor_col >= 5   # past "alpha "
end

@testset "b moves cursor to start of previous word" begin
    app, _ = _new_app()
    Ressac.TK.set_text!(Ressac._active_editor(app), "alpha beta")
    Ressac._active_editor(app).cursor_row = 1
    Ressac._active_editor(app).cursor_col = 7   # somewhere inside "beta"
    Ressac._active_editor(app).mode = :normal
    Tachikoma.update!(app, Tachikoma.KeyEvent('b'))
    @test Ressac._active_editor(app).cursor_col <= 6
end

# ── Dot-repeat ──────────────────────────────────────────────────────

@testset ". repeats the last text-mutating command" begin
    app, _ = _new_app()
    Ressac.TK.set_text!(Ressac._active_editor(app), "abcdef")
    Ressac._active_editor(app).cursor_row = 1
    Ressac._active_editor(app).cursor_col = 0
    Ressac._active_editor(app).mode = :normal
    Tachikoma.update!(app, Tachikoma.KeyEvent('x'))   # delete 'a'
    @test Ressac.TK.text(Ressac._active_editor(app)) == "bcdef"
    Tachikoma.update!(app, Tachikoma.KeyEvent('.'))   # repeat delete
    @test Ressac.TK.text(Ressac._active_editor(app)) == "cdef"
end

# ── Pattern :sg / :sn shortcuts ────────────────────────────────────

@testset ":sn-2 / :sg2.0 dispatch through shortcut path" begin
    app, _ = _new_app()
    # `:sn…` n'est pas « s + n » : c'est le saut de ligne avant, et il lui
    # faut un verbe. `:sn-2` n'en a pas → commande inconnue, buffer intact.
    _set_buffer!(app, "@d1 \"bd\"")
    _exec_ex_command!(app, "sn-2")
    @test _buffer_text(app) == "@d1 \"bd\""
    _exec_ex_command!(app, "sng2.0")
    @test _buffer_text(app) == "@d1 \"bd\"\n    |> gain(2.0)"
end

# ── Plugin sccode flows ────────────────────────────────────────────

@testset ":sc <query> doesn't crash on a string query" begin
    app, _ = _new_app()
    # Réseau coupé (helpers.jl) : l'erreur se lit, rien n'est importé.
    @test any(l -> occursin("[ERROR] sccode fetch reverb", l), _cmd_logs(app, "sc reverb"))
    # Avec une page servie : le SynthDef est écrit, enregistré, ouvert.
    with_clean_registries() do
        _SCCODE_PAGES["https://sccode.org/1-4Qy"] =
            "<pre>1\n2</pre><pre>SynthDef(\\uiitverb, { |out=0| Out.ar(out, SinOsc.ar(220)) }).add;</pre>"
        try
            _exec_ex_command!(app, "sc 1-4Qy")
            path = joinpath(pwd(), "plugins", "user-synths", "uiitverb.jl")       # converti en DSL à l'arrivée
            @test isfile(path) && occursin("@synth :uiitverb", read(path, String)) && occursin("sin_osc(220", read(path, String))
            @test Ressac.synth_info(:uiitverb) !== nothing
        finally
            delete!(_SCCODE_PAGES, "https://sccode.org/1-4Qy")
            empty!(Ressac._SCCODE_SOURCE_CACHE)
        end
    end
end

# ── Sccode aliasing ────────────────────────────────────────────────

@testset ":alias / :alias-rm round-trip" begin
    app, _ = _new_app()
    alias = "uiit_rm_$(rand(UInt16))"
    with_clean_registries() do
        _exec_ex_command!(app, "alias $alias bd")
        @test Ressac.resolve_synth_name(Symbol(alias)) === :bd
        @test any(l -> occursin("retiré", l), _cmd_logs(app, "alias-rm $alias"))
        @test Ressac.resolve_synth_name(Symbol(alias)) === Symbol(alias)
    end
end

# ── Ctrl-Shift-F toggle is observable across view frames ──────────

@testset "Ctrl-Shift-F toggles floats_hidden in any mode" begin
    app, _ = _new_app()
    @test app.floats_hidden == false
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'F'))
    @test app.floats_hidden == true
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'F'))
    @test app.floats_hidden == false
end

# ── Multi-workspace tree isolation ─────────────────────────────────

@testset "split state is per-workspace, not global" begin
    app, _ = _new_app()
    # WS 1: 1 leaf (default)
    @test length(collect(Ressac._all_leaves(
        Ressac.current_workspace(app.workspaces).tree))) == 1
    # Create WS 2 and split there only.
    Ressac.create_workspace!(app.workspaces, "ws2")
    Ressac.cmd_vsplit!(app.workspaces, "log", Dict{String,Any}())
    @test length(collect(Ressac._all_leaves(
        Ressac.current_workspace(app.workspaces).tree))) == 2
    # Switch back to WS 1 — still 1 leaf.
    app.workspaces.current_idx = 1
    @test length(collect(Ressac._all_leaves(
        Ressac.current_workspace(app.workspaces).tree))) == 1
end

@testset "fermer la pane des patterns est refusé : le texte reste à l'écran" begin
    app, frame = _new_app()
    text = _buffer_text(app)
    Ressac.cmd_vsplit!(app.workspaces, "scope", Dict{String,Any}("target" => "wave"))
    Ressac._focus_patterns!(app)
    @test !Ressac._close_focused_pane!(app)
    Tachikoma.view(app, frame)
    @test Ressac._patterns_editor(app) !== nothing && _buffer_text(app) == text
    # Un arbre qui aurait perdu ses patterns (fichier de disposition abîmé) est rebâti.
    ws = Ressac.current_workspace(app.workspaces)
    ws.tree = Ressac.PaneLeaf(ws.focused_pane, Ressac.PaneImpl[Ressac._pane_new(:log, Dict{String,Any}())], 1)
    Tachikoma.view(app, frame)
    @test Ressac._patterns_editor(app) !== nothing
end

@testset "content commands target a pane (no ambient _active_editor)" begin
    @testset "_open_or_reuse_editable_pane! reuses an EMPTY editor" begin
        app, _ = _new_app()
        Tachikoma.set_text!(Ressac._active_editor(app), "")   # make it empty
        ws = Ressac.current_workspace(app.workspaces)
        n_before = length(collect(Ressac._all_leaves(ws.tree)))
        ed = Ressac._open_or_reuse_editable_pane!(app)
        @test ed !== nothing
        @test length(collect(Ressac._all_leaves(ws.tree))) == n_before  # reused
    end

    @testset "_open_or_reuse_editable_pane! opens a NEW pane when none empty" begin
        app, _ = _new_app()
        # fill the default editor so it's non-empty
        Tachikoma.set_text!(Ressac._active_editor(app), "@d1 :bd")
        ws = Ressac.current_workspace(app.workspaces)
        n_before = length(collect(Ressac._all_leaves(ws.tree)))
        ed = Ressac._open_or_reuse_editable_pane!(app)
        @test ed !== nothing
        @test length(collect(Ressac._all_leaves(ws.tree))) == n_before + 1
        @test isempty(strip(Tachikoma.text(ed)))      # fresh, empty
    end

    @testset ":starter reuses the empty patterns pane, content lands there" begin
        app, _ = _new_app()
        ed0 = Ressac._active_editor(app)
        Tachikoma.set_text!(ed0, "")              # empty → must be reused
        ws = Ressac.current_workspace(app.workspaces)
        n_before = length(collect(Ressac._all_leaves(ws.tree)))
        Ressac._starter_command!(app, "house")
        ws2 = Ressac.current_workspace(app.workspaces)
        @test length(collect(Ressac._all_leaves(ws2.tree))) == n_before   # reused
        @test !isempty(strip(Tachikoma.text(ed0)))                        # seeded
    end

    @testset ":starter with a busy editor opens a new pane (no clobber)" begin
        app, _ = _new_app()
        Tachikoma.set_text!(Ressac._active_editor(app), "@d1 :bd*4")
        ws = Ressac.current_workspace(app.workspaces)
        n_before = length(collect(Ressac._all_leaves(ws.tree)))
        Ressac._starter_command!(app, "trap")     # exact starter, no panes spec
        ws2 = Ressac.current_workspace(app.workspaces)
        @test length(collect(Ressac._all_leaves(ws2.tree))) == n_before + 1
        # the busy editor must be untouched
        busy_intact = any(Ressac._all_leaves(ws2.tree)) do leaf
            any(leaf.tabs) do tab
                tab isa Ressac.EditorPane &&
                    any(t -> occursin("@d1 :bd*4", Tachikoma.text(t.code_editor)),
                        tab.tabs)
            end
        end
        @test busy_intact
    end
end

@testset "explorateur et onde — les ponts vers le texte du son" begin
    # test_pane_interface.jl vide _PANE_KINDS ; on (ré)enregistre les kinds
    # dont on a besoin ici.
    Ressac.register_pane_kind!(:explorer, Ressac._synth_explorer_pane_ctor)
    Ressac.register_pane_kind!(:waveform, Ressac._waveform_pane_ctor)

    @testset "M dans l'explorateur poste le candidat à ouvrir" begin
        Ressac._EXPLORER_SCULPT_REQUEST[] = nothing
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 5))
        @test Ressac.handle_key!(p, Tachikoma.KeyEvent('M')) == true
        @test Ressac._EXPLORER_SCULPT_REQUEST[] !== nothing
        Ressac._EXPLORER_SCULPT_REQUEST[] = nothing
    end

    @testset ":sculpt n'existe plus ; le son se travaille dans son texte" begin
        app, frame = _new_app()
        _exec_ex_command!(app, "sculpt")
        @test occursin("commande inconnue", app.logs[end])
        @test !("sculpt" in Ressac._command_completion_candidates(app, ""))
    end

    @testset "e dans une onde ouvre son son dans l'éditeur ; :w le range" begin
        old = Ressac._WAVE_RENDER[]
        Ressac._WAVE_RENDER[] = (g -> (Float32[0.0f0, 0.1f0], 44100))
        Ressac._EXPLORER_EXPORT_REQUEST[] = nothing
        path = joinpath(pwd(), "plugins", "user-synths", "scusave.jl")
        rm(path; force = true)
        app, frame = _new_app()
        try
            g = Ressac.archetype(:pluck)
            Ressac.cmd_split!(app.workspaces, "waveform",
                              Dict{String,Any}("genome" => Ressac.serialize_genome(g), "label" => "mybass"))
            @test Ressac._focused_pane_impl(app) isa Ressac.WaveformPane
            @test (Tachikoma.view(app, frame); true)
            Tachikoma.update!(app, Tachikoma.KeyEvent('e'))
            @test Ressac._EXPLORER_EXPORT_REQUEST[] === nothing        # export drainé
            @test app.volet === :son
            @test Ressac._focused_role(app) === :synth
            @test occursin("@synth :mybass", Tachikoma.text(Ressac._active_editor(app)))
            _exec_ex_command!(app, "w scusave")
            @test isfile(path) && occursin("@synth :scusave", read(path, String))
        finally
            Ressac._WAVE_RENDER[] = old
            Ressac._EXPLORER_EXPORT_REQUEST[] = nothing
            rm(path; force = true)
        end
    end
end
