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
