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
end
