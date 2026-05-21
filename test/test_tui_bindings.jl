using Test
using Ressac

# `_dispatch_key!` takes a `KeyEvent`-ish object exposing code/modifiers/kind.
# We use a NamedTuple in tests to avoid constructing real Crossterm events.
function _fake_key(code; mods=String[], kind="Press")
    return (; code=code, modifiers=mods, kind=kind)
end

@testset "tui_bindings" begin
    @testset "insert mode: printable char inserts" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.mode = :insert
        Ressac._dispatch_key!(m, _fake_key("a"))
        @test m.buffer == ["a"]
        @test m.cursor_col == 2
    end

    @testset "insert mode: Enter splits line" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.mode = :insert; m.buffer = ["abc"]; m.cursor_col = 3
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test m.buffer == ["ab", "c"]
    end

    @testset "insert mode: Esc switches to normal" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.mode = :insert
        Ressac._dispatch_key!(m, _fake_key("Esc"))
        @test m.mode === :normal
    end

    @testset "normal mode: i/a/o/O switch to insert" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.mode = :normal; m.buffer = ["xy"]; m.cursor_col = 1
        Ressac._dispatch_key!(m, _fake_key("a"))
        @test m.mode === :insert
        @test m.cursor_col == 2

        m.mode = :normal; m.cursor_col = 1
        Ressac._dispatch_key!(m, _fake_key("o"))
        @test m.mode === :insert
        @test m.cursor_row == 2
        @test m.buffer == ["xy", ""]
    end

    @testset "normal mode: hjkl + 0/\$ navigate" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.mode = :normal; m.buffer = ["abc", "defg"]; m.cursor_row = 1; m.cursor_col = 2
        Ressac._dispatch_key!(m, _fake_key("l"))
        @test m.cursor_col == 3
        Ressac._dispatch_key!(m, _fake_key("j"))
        @test m.cursor_row == 2
        Ressac._dispatch_key!(m, _fake_key("0"))
        @test m.cursor_col == 1
        Ressac._dispatch_key!(m, _fake_key("\$"))
        @test m.cursor_col == lastindex("defg") + 1
    end

    @testset "normal mode: dd deletes the current line" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.mode = :normal; m.buffer = ["a", "b", "c"]; m.cursor_row = 2
        Ressac._dispatch_key!(m, _fake_key("d"))  # primer
        @test m.pending_chord === :d
        Ressac._dispatch_key!(m, _fake_key("d"))  # commit
        @test m.buffer == ["a", "c"]
        @test m.pending_chord === :none
    end

    @testset "normal mode: count_prefix accumulates digits" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key("2"))
        @test m.count_prefix == 2
        Ressac._dispatch_key!(m, _fake_key("3"))
        @test m.count_prefix == 23
    end

    @testset "normal mode: gd<digits> chord triggers goto" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=1.0)
        m = Ressac.LiveModel(; scheduler=sched,
            buffer=["@d1 pure(:bd)", "", "@d2 pure(:sn)", "", "@d1 pure(:cp)"])
        m.mode = :normal; m.cursor_row = 3
        Ressac._dispatch_key!(m, _fake_key("g"))
        @test m.pending_chord === :g
        Ressac._dispatch_key!(m, _fake_key("d"))
        @test m.pending_chord === :gd
        Ressac._dispatch_key!(m, _fake_key("1"))
        @test m.chord_digits == "1"
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test m.pending_chord === :none
        # `gd1` from row 3: backward search finds row 1.
        @test m.cursor_row == 1
    end

    @testset "visual: V + j extends selection; y yanks; Esc cancels" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["a", "b", "c", "d"]
        m.cursor_row = 1; m.cursor_col = 1; m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key("V"))
        @test m.mode === :visual_line
        @test m.visual_anchor == (1, 1)
        Ressac._dispatch_key!(m, _fake_key("j"))
        Ressac._dispatch_key!(m, _fake_key("j"))
        Ressac._dispatch_key!(m, _fake_key("y"))
        @test m.mode === :normal
        @test m.yank == ["a", "b", "c"]
    end

    @testset "visual: d deletes selection and yanks" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["a", "b", "c", "d"]
        m.cursor_row = 2; m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key("V"))
        Ressac._dispatch_key!(m, _fake_key("j"))
        Ressac._dispatch_key!(m, _fake_key("d"))
        @test m.buffer == ["a", "d"]
        @test m.yank == ["b", "c"]
        @test m.mode === :normal
    end

    @testset "yy / p round-trip a single line" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["one", "two"]
        m.cursor_row = 1; m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key("y"))
        Ressac._dispatch_key!(m, _fake_key("y"))
        @test m.yank == ["one"]
        m.cursor_row = 2
        Ressac._dispatch_key!(m, _fake_key("p"))
        @test m.buffer == ["one", "two", "one"]
    end

    @testset "command mode: :q sets quit" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key(":"))
        @test m.mode === :command
        Ressac._dispatch_key!(m, _fake_key("q"))
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test m.quit
        @test m.mode === :normal
    end

    @testset "command mode: :cps 0.75 updates the scheduler" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        m = Ressac.LiveModel(; scheduler=sched); m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key(":"))
        for c in "cps 0.75"
            Ressac._dispatch_key!(m, _fake_key(string(c)))
        end
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test sched.cps == 0.75
    end

    @testset "normal mode: x at end of line clamps cursor" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["abc"]; m.cursor_row = 1; m.cursor_col = 3; m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key("x"))
        @test m.buffer == ["ab"]
        @test m.cursor_col == 2  # clamped from 3 to lastindex("ab") = 2
    end

    @testset "normal mode: Ctrl+C quits" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key("c"; mods=["Control"]))
        @test m.quit
    end

    @testset "normal mode: gg jumps to first line" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["a", "b", "c"]; m.cursor_row = 3; m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key("g"))
        @test m.pending_chord === :g
        Ressac._dispatch_key!(m, _fake_key("g"))
        @test m.cursor_row == 1
        @test m.pending_chord === :none
    end

    @testset "command mode: /@d1 jumps forward" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["foo", "@d1 pure(:bd)", "bar"]
        m.cursor_row = 1; m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key("/"))
        for c in "@d1"
            Ressac._dispatch_key!(m, _fake_key(string(c)))
        end
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test m.cursor_row == 2
    end

    @testset "normal mode: gd64<Enter> resolves with N=64" begin
        # Build a buffer with @d64 active.
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()),
            buffer=["@d64 pure(:bd)"])
        m.mode = :normal; m.cursor_row = 1
        Ressac._dispatch_key!(m, _fake_key("g"))
        Ressac._dispatch_key!(m, _fake_key("d"))
        for c in "64"
            Ressac._dispatch_key!(m, _fake_key(string(c)))
        end
        @test m.chord_digits == "64"
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test m.pending_chord === :none
        # last_search should be set to the d64 regex.
        @test m.last_search !== nothing
    end

    @testset "normal mode: gd<non-digit> with no digits logs error" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key("g"))
        Ressac._dispatch_key!(m, _fake_key("d"))
        # Now press a non-digit without typing any digits first.
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test any(l -> occursin("gd: no slot given", l), m.logs)
    end

    @testset "normal mode: gd<out of range> logs error" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key("g"))
        Ressac._dispatch_key!(m, _fake_key("d"))
        for c in "999"
            Ressac._dispatch_key!(m, _fake_key(string(c)))
        end
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test any(l -> occursin("out of range", l), m.logs)
    end

    @testset "normal mode: P pastes before current line" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["one", "two"]; m.cursor_row = 2; m.mode = :normal
        m.yank = ["X"]
        Ressac._dispatch_key!(m, _fake_key("P"))
        @test m.buffer == ["one", "X", "two"]
    end

    @testset "command mode: :goto d12 jumps to slot" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()),
            buffer=["foo", "@d12 pure(:bd)", "bar"])
        m.cursor_row = 1; m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key(":"))
        for c in "goto d12"
            Ressac._dispatch_key!(m, _fake_key(string(c)))
        end
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test m.cursor_row == 2
    end

    @testset "command mode: unknown :cmd logs error" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key(":"))
        for c in "fubar"
            Ressac._dispatch_key!(m, _fake_key(string(c)))
        end
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test any(l -> occursin("unknown command", l), m.logs)
    end
end
