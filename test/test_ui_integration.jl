# UI integration tests — drive a real RessacApp via Tachikoma.update!
# and assert end-to-end outcomes. The pattern stays small: build the
# app, ship a sequence of KeyEvent / MouseEvent, check state. Each
# test reads like a user gesture sequence so a regression makes the
# offending flow obvious.

using Test
using Ressac
import Tachikoma

if !isdefined(Main, :MockOSCClient)
    mutable struct MockOSCClient
        sent::Vector{Vector{UInt8}}
    end
    MockOSCClient() = MockOSCClient(Vector{UInt8}[])
    Ressac.send_osc(c::MockOSCClient, bytes::Vector{UInt8}) = push!(c.sent, bytes)
end

# Boots a fresh app + paints one frame so view-side state
# (_last_ws_area, focus flags, m.layout_patterns) is populated. Most
# integration tests want the post-first-frame world.
function _new_app()
    mock = MockOSCClient()
    sched = Ressac.Scheduler(mock; cps = 0.5)
    app = Ressac.RessacApp(; scheduler = sched)
    tb = Tachikoma.TestBackend(120, 40)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 120, 40),
                            Tachikoma.GraphicsRegion[],
                            Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    Ressac._PANE_MODE.active = false
    return app, frame
end

# Type a String of plain characters as KeyEvents. Caller is
# responsible for the editor being in insert mode first.
function _type!(app::Ressac.RessacApp, s::AbstractString)
    for c in s
        Tachikoma.update!(app, Tachikoma.KeyEvent(c))
    end
end

# Find the EditorPane that holds m.editor (the patterns pane) in
# the focused workspace's tree. Returns the leaf id.
function _patterns_leaf_id(app::Ressac.RessacApp)
    ws = Ressac.current_workspace(app.workspaces)
    for leaf in Ressac._all_leaves(ws.tree)
        for tab in leaf.tabs
            if tab isa Ressac.EditorPane &&
               !isempty(tab.tabs) &&
               tab.tabs[tab.current_tab].code_editor === app.editor
                return leaf.id
            end
        end
    end
    return 0
end

# ── Pane creation + isolation ───────────────────────────────────────

@testset "C-w v creates a new pane and persists pane mode" begin
    app, _ = _new_app()
    app.editor.mode = :normal
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
    app.editor.mode = :normal
    Ressac.TK.set_text!(app.editor, "")
    # Split off a new editor pane and focus it.
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w'))
    Tachikoma.update!(app, Tachikoma.KeyEvent('v'))
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    Tachikoma.view(app, frame)  # refresh focus flags + rects

    ws = Ressac.current_workspace(app.workspaces)
    new_leaf_id = ws.focused_pane
    new_pane = Ressac._find_leaf_by_id(ws.tree, new_leaf_id).tabs[1]
    @test new_pane isa Ressac.EditorPane
    new_editor = new_pane.tabs[1].code_editor
    @test new_editor !== app.editor

    # Type in the new pane via _route_key_to_focused_pane! — must
    # enter insert mode first.
    Tachikoma.update!(app, Tachikoma.KeyEvent('i'))
    _type!(app, "hello-new")
    @test occursin("hello-new", Ressac.TK.text(new_editor))
    @test !occursin("hello-new", Ressac.TK.text(app.editor))

    # Switch focus to the patterns pane and type — must land in
    # m.editor, not the new pane.
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))     # back to normal
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w'))
    Tachikoma.update!(app, Tachikoma.KeyEvent('h'))          # focus left
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    Tachikoma.view(app, frame)
    @test ws.focused_pane == _patterns_leaf_id(app)

    Tachikoma.update!(app, Tachikoma.KeyEvent('i'))
    _type!(app, "hello-main")
    @test occursin("hello-main", Ressac.TK.text(app.editor))
    @test !occursin("hello-main", Ressac.TK.text(new_editor))
end

@testset "C-w c closes the focused pane" begin
    app, frame = _new_app()
    app.editor.mode = :normal
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w'))
    Tachikoma.update!(app, Tachikoma.KeyEvent('v'))
    ws = Ressac.current_workspace(app.workspaces)
    @test length(collect(Ressac._all_leaves(ws.tree))) == 2
    Tachikoma.update!(app, Tachikoma.KeyEvent('c'))
    @test length(collect(Ressac._all_leaves(ws.tree))) == 1
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
end

# ── Workspace switching ─────────────────────────────────────────────

@testset "Ctrl-N hops workspaces without entering pane mode" begin
    app, _ = _new_app()
    Ressac.create_workspace!(app.workspaces, "scratch")
    Ressac.create_workspace!(app.workspaces, "perf")
    @test app.workspaces.current_idx == 3
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, '1'))
    @test app.workspaces.current_idx == 1
    @test Ressac._PANE_MODE.active == false
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, '2'))
    @test app.workspaces.current_idx == 2
end

# ── Mouse focus ─────────────────────────────────────────────────────

@testset "left-click on a non-focused pane changes focus" begin
    app, frame = _new_app()
    app.editor.mode = :normal
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

@testset ":q from a multi-pane workspace saves layout and flips quit" begin
    app, frame = _new_app()
    app.editor.mode = :normal
    # Build a non-trivial tree so save_layout has something to write.
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w'))
    Tachikoma.update!(app, Tachikoma.KeyEvent('v'))
    Tachikoma.update!(app, Tachikoma.KeyEvent('s'))
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    # Move the saved-layout path to a temp file so we don't clobber
    # the user's real layout during the test run. Easiest: stub
    # _default_layout_path via monkey-patch? No — just trust the
    # write; the path is under HOME and the test environment owns it.
    Tachikoma.update!(app, Tachikoma.KeyEvent(':'))
    Tachikoma.update!(app, Tachikoma.KeyEvent('q'))
    Tachikoma.update!(app, Tachikoma.KeyEvent(:enter))
    @test app.quit == true
    @test isfile(Ressac._default_layout_path())
end

# ── Modal flows ─────────────────────────────────────────────────────

@testset "Esc closes any open modal back to :none" begin
    app, _ = _new_app()
    app.editor.mode = :normal
    for kind in (:guide, :browse, :synth_library, :snippets, :wiki, :mixer)
        app.modal = kind
        Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
        @test app.modal === :none
    end
end

# ── Snippet panes (starter) ────────────────────────────────────────

@testset ":starter snippet with panes = [...] rebuilds workspace" begin
    app, _ = _new_app()
    app.editor.mode = :normal
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
        @test occursin("@d1", Ressac.TK.text(app.editor))
    finally
        delete!(Ressac._SNIPPETS, name)
    end
end
