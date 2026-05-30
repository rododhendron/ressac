using Test
using Ressac
import Tachikoma

# The LiveModel-rendered TUI.view tests that lived here were removed
# in the phase-1 cleanup that deleted tui_view.jl. The kept test
# (live API helpers without an active session) is independent of any
# UI model and belongs in the live_api regression set.

@testset "live API errors without an active session" begin
    Ressac._LIVE_SCHEDULER[] = nothing
    @test_throws ErrorException d!(:d1, pure(:bd))
    @test_throws ErrorException unset!(:d1)
    @test_throws ErrorException hush_all!()
    @test_throws ErrorException cps!(0.5)
end

# Sub-project 9 — workspace bootstrap. Reuses the same MockOSCClient
# convention as test_scheduler.jl / test_sc_autodiscover.jl.
if !isdefined(Main, :MockOSCClient)
    mutable struct MockOSCClient
        sent::Vector{Vector{UInt8}}
    end
    MockOSCClient() = MockOSCClient(Vector{UInt8}[])
    Ressac.send_osc(c::MockOSCClient, bytes::Vector{UInt8}) = push!(c.sent, bytes)
end

@testset "_ensure_default_workspace! initializes one editor pane" begin
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

    # Idempotent — calling again doesn't create another workspace.
    Ressac._ensure_default_workspace!(app)
    @test length(app.workspaces.workspaces) == 1
end

# Helper: read one row of a Tachikoma Buffer as a String. Tachikoma
# stores cells in a flat content vector indexed via (y - area.y) *
# width + (x - area.x) + 1 — we just map that lookup over a row.
function _row_to_string(buf::Tachikoma.Buffer, y::Int)
    cells = Char[]
    for x in buf.area.x : (buf.area.x + buf.area.width - 1)
        idx = (y - buf.area.y) * buf.area.width + (x - buf.area.x) + 1
        if 1 <= idx <= length(buf.content)
            push!(cells, buf.content[idx].char)
        end
    end
    return String(cells)
end

@testset "_render_workspace_strip! draws workspace labels" begin
    mock = MockOSCClient()
    sched = Scheduler(mock; cps=0.5)
    app = Ressac.RessacApp(; scheduler=sched)
    Ressac.create_workspace!(app.workspaces, "live")
    Ressac.create_workspace!(app.workspaces, "synth")
    app.workspaces.current_idx = 1
    tb = Tachikoma.TestBackend(60, 5)
    Ressac._render_workspace_strip!(app, Tachikoma.Rect(1, 1, 60, 1), tb.buf)
    row = _row_to_string(tb.buf, 1)
    @test occursin("[1: live]", row)
    @test occursin("[2: synth]", row)
end

@testset "TK.view dispatches through WorkspaceManager (smoke)" begin
    mock = MockOSCClient()
    sched = Scheduler(mock; cps=0.5)
    app = Ressac.RessacApp(; scheduler=sched)
    tb = Tachikoma.TestBackend(80, 30)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 80, 30),
                            Tachikoma.GraphicsRegion[],
                            Tachikoma.PixelSnapshot[])
    # First view triggers _ensure_default_workspace! and binds the
    # workspace's default EditorPane to m.editor.
    Tachikoma.view(app, frame)
    ws = Ressac.current_workspace(app.workspaces)
    @test ws !== nothing
    leaf = ws.tree
    @test leaf isa Ressac.PaneLeaf
    @test length(leaf.tabs) == 1
    @test leaf.tabs[1] isa Ressac.EditorPane
    @test leaf.tabs[1].tabs[1].code_editor === app.editor
    # After the first frame, m.layout_patterns is populated from the
    # leaf rect so legacy overlay paths still work.
    @test app.layout_patterns !== nothing
end

@testset "Ctrl-N jumps workspaces and Ctrl-Shift-F toggles floats" begin
    mock = MockOSCClient()
    sched = Scheduler(mock; cps=0.5)
    app = Ressac.RessacApp(; scheduler=sched)
    Ressac._ensure_default_workspace!(app)
    Ressac.create_workspace!(app.workspaces, "live")
    Ressac.create_workspace!(app.workspaces, "synth")
    Ressac._PANE_MODE.active = false
    @test app.workspaces.current_idx == 3
    # Ctrl-1 → workspace 1
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, '1'))
    @test app.workspaces.current_idx == 1
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, '3'))
    @test app.workspaces.current_idx == 3
    # Ctrl-Shift-F (sent as :ctrl 'F') toggles floats_hidden
    @test app.floats_hidden == false
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'F'))
    @test app.floats_hidden == true
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'F'))
    @test app.floats_hidden == false
end

@testset "Ctrl-W in editor normal mode enters pane mode; v splits" begin
    mock = MockOSCClient()
    sched = Scheduler(mock; cps=0.5)
    app = Ressac.RessacApp(; scheduler=sched)
    Ressac._ensure_default_workspace!(app)
    app.editor.mode = :normal
    Ressac._PANE_MODE.active = false
    Ressac._PANE_MODE.sticky = false
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w'))
    @test Ressac._PANE_MODE.active == true
    # 'v' in pane mode splits vertically with an editor pane.
    ws = Ressac.current_workspace(app.workspaces)
    nleaves_before = length(collect(Ressac._all_leaves(ws.tree)))
    Tachikoma.update!(app, Tachikoma.KeyEvent('v'))
    @test length(collect(Ressac._all_leaves(ws.tree))) == nleaves_before + 1
    # Single-shot: pane mode auto-exits after a consumed key.
    @test Ressac._PANE_MODE.active == false
end

@testset "Tab inside pane mode toggles sticky" begin
    mock = MockOSCClient()
    sched = Scheduler(mock; cps=0.5)
    app = Ressac.RessacApp(; scheduler=sched)
    Ressac._ensure_default_workspace!(app)
    app.editor.mode = :normal
    Ressac._PANE_MODE.active = false
    Ressac._PANE_MODE.sticky = false
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w'))
    Tachikoma.update!(app, Tachikoma.KeyEvent(:tab))
    @test Ressac._PANE_MODE.sticky == true
    # Now sticky: 'v' splits but mode stays active.
    Tachikoma.update!(app, Tachikoma.KeyEvent('v'))
    @test Ressac._PANE_MODE.active == true
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    @test Ressac._PANE_MODE.active == false
    @test Ressac._PANE_MODE.sticky == false
end

@testset "key routing — focused non-patterns pane receives keys" begin
    mock = MockOSCClient()
    sched = Scheduler(mock; cps=0.5)
    app = Ressac.RessacApp(; scheduler=sched)
    Ressac._ensure_default_workspace!(app)
    # Split into a log pane; focus moves to the new leaf.
    Ressac.cmd_vsplit!(app.workspaces, "log", Dict{String,Any}())
    ws = Ressac.current_workspace(app.workspaces)
    leaf = Ressac._find_leaf_by_id(ws.tree, ws.focused_pane)
    @test leaf.tabs[1] isa Ressac.LogPane
    log_pane = leaf.tabs[1]
    @test log_pane.scroll == 0
    # 'k' is bound to "scroll log up" inside LogPane.handle_key!.
    # When the focused pane is the log, _route_key_to_focused_pane!
    # should return true and the log's scroll should bump.
    Tachikoma.update!(app, Tachikoma.KeyEvent('k'))
    @test log_pane.scroll == 1
end

@testset "key routing — patterns pane stays on legacy m.editor path" begin
    mock = MockOSCClient()
    sched = Scheduler(mock; cps=0.5)
    app = Ressac.RessacApp(; scheduler=sched)
    Ressac._ensure_default_workspace!(app)
    ws = Ressac.current_workspace(app.workspaces)
    # Focused pane is the default editor (m.editor).
    @test ws.focused_pane == ws.tree.id
    # _route_key_to_focused_pane! returns false → legacy path runs.
    @test Ressac._route_key_to_focused_pane!(app, Tachikoma.KeyEvent('i')) == false
end

@testset "_render_workspace_strip! shows pane mode badge when active" begin
    mock = MockOSCClient()
    sched = Scheduler(mock; cps=0.5)
    app = Ressac.RessacApp(; scheduler=sched)
    Ressac.create_workspace!(app.workspaces, "live")
    Ressac._PANE_MODE.active = false
    Ressac._PANE_MODE.sticky = false
    tb = Tachikoma.TestBackend(80, 5)
    Ressac._render_workspace_strip!(app, Tachikoma.Rect(1, 1, 80, 1), tb.buf)
    @test !occursin("PANE", _row_to_string(tb.buf, 1))

    Ressac._PANE_MODE.active = true
    tb2 = Tachikoma.TestBackend(80, 5)
    Ressac._render_workspace_strip!(app, Tachikoma.Rect(1, 1, 80, 1), tb2.buf)
    @test occursin("PANE", _row_to_string(tb2.buf, 1))
    @test occursin("single-shot", _row_to_string(tb2.buf, 1))

    Ressac._PANE_MODE.sticky = true
    tb3 = Tachikoma.TestBackend(80, 5)
    Ressac._render_workspace_strip!(app, Tachikoma.Rect(1, 1, 80, 1), tb3.buf)
    @test occursin("STICKY", _row_to_string(tb3.buf, 1))

    Ressac._PANE_MODE.active = false
    Ressac._PANE_MODE.sticky = false
end

@testset ":layout save / :layout load round-trip" begin
    mock = MockOSCClient()
    sched = Scheduler(mock; cps=0.5)
    app = Ressac.RessacApp(; scheduler=sched)
    Ressac._ensure_default_workspace!(app)
    # Split so we save a non-trivial tree.
    Ressac.cmd_vsplit!(app.workspaces, "log", Dict{String,Any}())
    n_before = length(collect(Ressac._all_leaves(
        Ressac.current_workspace(app.workspaces).tree)))
    @test n_before == 2
    name = "test-layout-$(rand(UInt32))"
    Ressac._layout_save!(app, name)
    @test isfile(Ressac._named_layout_path(name))
    # Reset to single pane.
    empty!(app.workspaces.workspaces)
    app.workspaces.current_idx = 0
    Ressac._ensure_default_workspace!(app)
    @test length(collect(Ressac._all_leaves(
        Ressac.current_workspace(app.workspaces).tree))) == 1
    # Load restores the split.
    Ressac._layout_load!(app, name)
    @test length(collect(Ressac._all_leaves(
        Ressac.current_workspace(app.workspaces).tree))) == 2
    # Cleanup the persisted file.
    rm(Ressac._named_layout_path(name); force=true)
end

@testset "_workspace_mouse_dispatch! focuses the clicked leaf" begin
    mock = MockOSCClient()
    sched = Scheduler(mock; cps=0.5)
    app = Ressac.RessacApp(; scheduler=sched)
    tb = Tachikoma.TestBackend(80, 30)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 80, 30),
                            Tachikoma.GraphicsRegion[],
                            Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    # Split the default pane horizontally with a log pane.
    Ressac.cmd_vsplit!(app.workspaces, "log", Dict{String,Any}())
    Tachikoma.view(app, frame)  # repopulate _last_ws_area + rects
    ws = Ressac.current_workspace(app.workspaces)
    # After vsplit, the focused pane is the new (log) leaf.
    log_leaf_id = ws.focused_pane
    # Click far left into the patterns leaf (column 1 lands inside it).
    evt = Tachikoma.MouseEvent(1, 5, Tachikoma.mouse_left, Tachikoma.mouse_press,
                                false, false, false)
    Ressac._workspace_mouse_dispatch!(app, evt)
    @test ws.focused_pane != log_leaf_id  # focus moved off the log pane
end

@testset "_global_log_tail_height collapses when a :log pane exists" begin
    mock = MockOSCClient()
    sched = Scheduler(mock; cps=0.5)
    app = Ressac.RessacApp(; scheduler=sched)
    Ressac._ensure_default_workspace!(app)
    @test Ressac._global_log_tail_height(app) == 10
    ws = Ressac.current_workspace(app.workspaces)
    push!(ws.tree.tabs, Ressac._pane_new(:log, Dict{String,Any}()))
    @test Ressac._global_log_tail_height(app) == 0
end
