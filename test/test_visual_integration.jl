# Visual integration tests — drive a real RessacApp through view()
# and assert on the rendered character buffer. Catches "I typed but
# nothing appeared" regressions that pure-state e2e tests miss.
#
# Pattern: build the app, send keystrokes, call view(), then look at
# Tachikoma.row_text(tb, y) for the expected text at expected rows.

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

const _VIS_W = 120
const _VIS_H = 35

function _vis_app()
    mock = MockOSCClient()
    sched = Ressac.Scheduler(mock; cps = 0.5)
    app = Ressac.RessacApp(; scheduler = sched)
    tb = Tachikoma.TestBackend(_VIS_W, _VIS_H)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, _VIS_W, _VIS_H),
                            Tachikoma.GraphicsRegion[],
                            Tachikoma.PixelSnapshot[])
    # First view triggers _ensure_default_workspace! so subsequent
    # cmd_vsplit / cmd_focus / etc. operate on a real workspace
    # instead of no-op'ing on an empty manager.
    Tachikoma.view(app, frame)
    Ressac._PANE_MODE.active = false
    return app, tb, frame
end

# Find the first row whose rendered text contains `needle`. Returns
# 0 if nothing matches — caller can assert `> 0` for "appears
# somewhere" or compare to a specific expected row.
function _find_row(tb, needle::AbstractString)
    for y in 1:_VIS_H
        occursin(needle, Tachikoma.row_text(tb, y)) && return y
    end
    return 0
end

# ── Command line — the regression that drove this whole refactor ────

@testset "':' enters command mode and the bar shows on screen" begin
    app, tb, frame = _vis_app()
    Tachikoma.view(app, frame)
    @test app.command_line.mode === :idle
    Tachikoma.update!(app, Tachikoma.KeyEvent(':'))
    Tachikoma.view(app, frame)
    @test app.command_line.mode === :command
    # The bar renders a `:` somewhere in the bottom chrome.
    found = _find_row(tb, ":")
    @test found > 0
end

@testset "typing ':hush' shows `:hush` in the chrome bar" begin
    app, tb, frame = _vis_app()
    Tachikoma.view(app, frame)
    Tachikoma.update!(app, Tachikoma.KeyEvent(':'))
    for c in "hush"
        Tachikoma.update!(app, Tachikoma.KeyEvent(c))
    end
    Tachikoma.view(app, frame)
    @test _find_row(tb, ":hush") > 0
end

@testset "command bar visible from a focused side pane too" begin
    app, tb, frame = _vis_app()
    Tachikoma.view(app, frame)
    # Vsplit a log pane → focus moves to the new (non-patterns) leaf.
    Ressac.cmd_vsplit!(app.workspaces, "log", Dict{String,Any}())
    Tachikoma.view(app, frame)
    ws = Ressac.current_workspace(app.workspaces)
    @test Ressac._find_leaf_by_id(ws.tree, ws.focused_pane).tabs[1] isa Ressac.LogPane
    Tachikoma.update!(app, Tachikoma.KeyEvent(':'))
    for c in "panic"
        Tachikoma.update!(app, Tachikoma.KeyEvent(c))
    end
    Tachikoma.view(app, frame)
    # CommandLine is a chrome row, independent of which pane has
    # focus — even with the log pane focused, `:panic` must show.
    @test _find_row(tb, ":panic") > 0
end

@testset "Esc cancels the command bar — text disappears" begin
    app, tb, frame = _vis_app()
    Tachikoma.view(app, frame)
    Tachikoma.update!(app, Tachikoma.KeyEvent(':'))
    for c in "abc"
        Tachikoma.update!(app, Tachikoma.KeyEvent(c))
    end
    Tachikoma.view(app, frame)
    @test _find_row(tb, ":abc") > 0
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    Tachikoma.view(app, frame)
    @test app.command_line.mode === :idle
    @test _find_row(tb, ":abc") == 0
end

@testset "Tab completion picker replaces the log tail when active" begin
    app, tb, frame = _vis_app()
    Tachikoma.view(app, frame)
    Tachikoma.update!(app, Tachikoma.KeyEvent(':'))
    for c in "hu"
        Tachikoma.update!(app, Tachikoma.KeyEvent(c))
    end
    Tachikoma.update!(app, Tachikoma.KeyEvent(:tab))
    Tachikoma.view(app, frame)
    @test Ressac.completion_active(app.command_line)
    # The COMPLETIONS title appears where the LOG title used to be.
    @test _find_row(tb, "COMPLETIONS") > 0
    # And the cycled candidate appears in the picker.
    @test _find_row(tb, "hush") > 0
end

# ── Workspace strip + status bar visibility ─────────────────────────

@testset "workspace strip shows [1] on top row" begin
    app, tb, frame = _vis_app()
    Tachikoma.view(app, frame)
    @test occursin("[1", Tachikoma.row_text(tb, 1))
end

@testset "status bar shows 'NORMAL @ patterns' by default" begin
    app, tb, frame = _vis_app()
    Tachikoma.view(app, frame)
    # Row 2 is the status bar in the current layout.
    @test occursin("NORMAL", Tachikoma.row_text(tb, 2))
end

@testset "status bar switches to 'COMMAND' when command bar is active" begin
    app, tb, frame = _vis_app()
    Tachikoma.view(app, frame)
    Tachikoma.update!(app, Tachikoma.KeyEvent(':'))
    Tachikoma.view(app, frame)
    @test occursin("COMMAND", Tachikoma.row_text(tb, 2))
end

@testset "workspace strip carries the pane-mode cheat sheet" begin
    app, tb, frame = _vis_app()
    Tachikoma.view(app, frame)
    Ressac._active_editor(app).mode = :normal
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w'))
    Tachikoma.view(app, frame)
    row1 = Tachikoma.row_text(tb, 1)
    @test occursin("split", row1) || occursin("focus", row1)
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
end

# ── Pane block + focus accent ───────────────────────────────────────

@testset "Default workspace renders a PATTERNS-titled pane block" begin
    app, tb, frame = _vis_app()
    Tachikoma.view(app, frame)
    @test _find_row(tb, "PATTERNS") > 0
end

@testset "after C-w v, two PATTERNS blocks are visible side by side" begin
    app, tb, frame = _vis_app()
    Tachikoma.view(app, frame)
    Ressac._active_editor(app).mode = :normal
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w'))
    Tachikoma.update!(app, Tachikoma.KeyEvent('v'))
    Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
    Tachikoma.view(app, frame)
    # Count PATTERNS occurrences on the workspace top row (around y=3).
    title_row_hits = 0
    for y in 3:6
        title_row_hits += count("PATTERNS", Tachikoma.row_text(tb, y))
    end
    @test title_row_hits >= 2
end

# ── Editor buffer shows typed text ──────────────────────────────────

@testset "typing in insert mode shows the chars in the pane body" begin
    app, tb, frame = _vis_app()
    Tachikoma.view(app, frame)
    Ressac.TK.set_text!(Ressac._active_editor(app), "")
    Ressac._active_editor(app).mode = :normal
    Tachikoma.update!(app, Tachikoma.KeyEvent('i'))
    for c in "alphabeta"
        Tachikoma.update!(app, Tachikoma.KeyEvent(c))
    end
    Tachikoma.view(app, frame)
    @test _find_row(tb, "alphabeta") > 0
end

# ── Livedoc / footer / log rows present at expected positions ───────

@testset "footer hint row contains 'NORMAL' or mode legend" begin
    app, tb, frame = _vis_app()
    Tachikoma.view(app, frame)
    # Footer (hint widget) is one row above the log tail.
    log_top_y = 0
    for y in 1:_VIS_H
        occursin("LOG", Tachikoma.row_text(tb, y)) && (log_top_y = y; break)
    end
    @test log_top_y > 0
    footer_y = log_top_y - 1
    @test footer_y > 0
    row = Tachikoma.row_text(tb, footer_y)
    @test !isempty(strip(row))   # the footer has SOME hint visible
end

@testset "TuningPane renders title with scale name + footer with period" begin
    app, tb, frame = _vis_app()
    Ressac.cmd_vsplit!(app.workspaces, "tuning",
                       Dict{String,Any}("name" => "major"))
    Tachikoma.view(app, frame)
    # Title bar carries "TUNING · :major" somewhere
    @test _find_row(tb, "TUNING") > 0
    @test _find_row(tb, "major") > 0
    # Footer line shows period in cents
    @test _find_row(tb, "1200") > 0
end

@testset "TuningPane footer shows label mode + 'press r to toggle'" begin
    app, tb, frame = _vis_app()
    Ressac.cmd_vsplit!(app.workspaces, "tuning",
                       Dict{String,Any}("name" => "major"))
    Tachikoma.view(app, frame)
    @test _find_row(tb, "press r to toggle") > 0
    @test _find_row(tb, "cents") > 0
end

@testset "TuningPane 'r' key toggles label mode" begin
    app, tb, frame = _vis_app()
    Ressac.cmd_vsplit!(app.workspaces, "tuning",
                       Dict{String,Any}("name" => "major"))
    ws = Ressac.current_workspace(app.workspaces)
    pane = Ressac._find_leaf_by_id(ws.tree, ws.focused_pane).tabs[1]
    @test pane.label_mode === :cents
    Tachikoma.update!(app, Tachikoma.KeyEvent('r'))
    @test pane.label_mode === :ratio
    Tachikoma.update!(app, Tachikoma.KeyEvent('r'))
    @test pane.label_mode === :cents
end

@testset "TuningPane handles unknown scale name gracefully" begin
    app, tb, frame = _vis_app()
    Ressac.cmd_vsplit!(app.workspaces, "tuning",
                       Dict{String,Any}("name" => "nonexistent-zzz"))
    Tachikoma.view(app, frame)
    @test _find_row(tb, "not found") > 0 || _find_row(tb, "unknown") > 0
end

@testset "push_played_note! decays after TTL" begin
    Ressac._LAST_NOTES[] = Tuple{Float64,Float64}[]
    Ressac.push_played_note!(60.0)
    @test length(Ressac._LAST_NOTES[]) == 1
    # Force an old entry to land — push one beyond the TTL.
    push!(Ressac._LAST_NOTES[], (72.0, time() - 10.0))
    Ressac.push_played_note!(64.0)
    # The old one should have been pruned.
    @test all((time() - t) <= Ressac._LAST_NOTES_TTL for (_, t) in Ressac._LAST_NOTES[])
end

# ── Tick rendering and recently-played highlight ────────────────────

@testset "TuningPane render places one tick per scale degree" begin
    Ressac._LAST_NOTES[] = Tuple{Float64,Float64}[]
    app, tb, frame = _vis_app()
    Ressac.cmd_vsplit!(app.workspaces, "tuning",
                       Dict{String,Any}("name" => "major"))
    Tachikoma.view(app, frame)
    # 7 degrees → at least 7 ○ ticks on the pane (some may overlap
    # in cell space when the pane is small but normally all visible).
    rendered = join((Tachikoma.row_text(tb, y) for y in 1:_VIS_H), '\n')
    n_open = count("○", rendered)
    @test n_open >= 5   # tolerate a couple of overlaps in cell rounding
end

@testset "TuningPane lights a tick after push_played_note! at root" begin
    Ressac._LAST_NOTES[] = Tuple{Float64,Float64}[]
    app, tb, frame = _vis_app()
    Ressac.cmd_vsplit!(app.workspaces, "tuning",
                       Dict{String,Any}("name" => "major"))
    # Push a note at exactly the root → degree 0 (0 cents → 0 semitones)
    Ressac.push_played_note!(0.0)
    Tachikoma.view(app, frame)
    rendered = join((Tachikoma.row_text(tb, y) for y in 1:_VIS_H), '\n')
    # At least one ● appears (the lit root tick).
    @test occursin("●", rendered)
end

# ── End-to-end via the scheduler — :note flows through OSC ──────────

@testset "pat |> scale(s) ships :note OSC value via the scheduler" begin
    Ressac._LAST_NOTES[] = Tuple{Float64,Float64}[]
    mock = MockOSCClient()
    sched = Ressac.Scheduler(mock; cps = 0.5)
    sched.t_start = 0.0
    # 0 2 4 in major → note semitones 0, 4, 7
    p = "0 2 4" |> Ressac.scale(:major)
    Ressac.set_pattern!(sched, :d1, p)
    # Step through one cycle.
    Ressac._step!(sched, 2.5)   # cps=0.5 → 2.5s = 1.25 cycles
    # 3 events fired → :note pushed for each
    @test length(Ressac._LAST_NOTES[]) >= 3
    pushed = [v for (v, _) in Ressac._LAST_NOTES[]]
    @test 0.0 in pushed
    @test 4.0 in pushed
    @test 7.0 in pushed
end

@testset "global log tail collapses when a LogPane is in the tree" begin
    app, tb, frame = _vis_app()
    Tachikoma.view(app, frame)
    @test _find_row(tb, "LOG") > 0
    Ressac.cmd_vsplit!(app.workspaces, "log", Dict{String,Any}())
    Tachikoma.view(app, frame)
    # Default chrome height is 10 when no LogPane is in the tree; the
    # workspace area expands by ~10 rows when one is present. We
    # assert the COLLAPSE side: the chrome LOG title is gone.
    found = _find_row(tb, " LOG ")
    @test found == 0 || found > _VIS_H - 5   # tolerate spurious "LOG" in pane title
end
