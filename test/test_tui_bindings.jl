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

    @testset "normal K previews sample under cursor" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            Ressac.register_sample!(Ressac.SampleEntry(:kicky, "p",
                "/tmp/k.wav", ["/tmp/k.wav"], Dict{String,Any}()))
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["@d1 p\"kicky sn\""]
            m.cursor_row = 1
            m.cursor_col = 9
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key("K"))

            play = [Ressac.decode_message(b) for b in mock.sent
                    if Ressac.decode_message(b).address == "/dirt/play"]
            @test length(play) == 1
            @test play[1].args == Any["s", "kicky", "cut", Int32(Ressac._PREVIEW_CUT_GROUP)]
            @test any(l -> occursin("preview sample kicky", l), m.logs)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset "K with :N suffix sends n parameter" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            Ressac.register_sample!(Ressac.SampleEntry(:snares, "p",
                "/tmp/snares", ["/tmp/s1.wav", "/tmp/s2.wav"], Dict{String,Any}()))
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["snares:1"]
            m.cursor_row = 1
            m.cursor_col = 1
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key("K"))

            play = [Ressac.decode_message(b) for b in mock.sent
                    if Ressac.decode_message(b).address == "/dirt/play"]
            @test length(play) == 1
            @test play[1].args == Any["s", "snares", "n", Int32(1),
                                       "cut", Int32(Ressac._PREVIEW_CUT_GROUP)]
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset "K on unknown sample logs WARN, no OSC sent" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["whatever"]
            m.cursor_row = 1
            m.cursor_col = 1
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key("K"))
            @test isempty(mock.sent)
            @test any(l -> occursin("no instrument/sample/synth", l), m.logs)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset "K previews instrument: expands declared params" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            Ressac.register_instrument!(Ressac.InstrumentEntry(
                :kicklourd, "p",
                Pair{String,Any}["s" => "bd", "n" => 3, "gain" => 1.2],
                Dict{String,Any}(),
            ))
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["kicklourd"]
            m.cursor_row = 1
            m.cursor_col = 1
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key("K"))

            play = [Ressac.decode_message(b) for b in mock.sent
                    if Ressac.decode_message(b).address == "/dirt/play"]
            @test length(play) == 1
            @test play[1].args == Any["s", "bd", "n", Int32(3), "gain", Float32(1.2),
                                       "cut", Int32(Ressac._PREVIEW_CUT_GROUP)]
            @test any(l -> occursin("preview instrument kicklourd", l), m.logs)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            empty!(Ressac._INSTRUMENT_REGISTRY)
        end
    end

    @testset "K instrument with :N suffix overrides preset n" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            Ressac.register_instrument!(Ressac.InstrumentEntry(
                :kicklourd, "p",
                Pair{String,Any}["s" => "bd", "n" => 3, "gain" => 1.2],
                Dict{String,Any}(),
            ))
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["kicklourd:7"]
            m.cursor_row = 1
            m.cursor_col = 1
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key("K"))

            play = [Ressac.decode_message(b) for b in mock.sent
                    if Ressac.decode_message(b).address == "/dirt/play"]
            @test play[1].args == Any["s", "bd", "n", Int32(7), "gain", Float32(1.2),
                                       "cut", Int32(Ressac._PREVIEW_CUT_GROUP)]
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            empty!(Ressac._INSTRUMENT_REGISTRY)
        end
    end

    @testset "K previews synth: bare /dirt/play s name" begin
        empty!(Ressac._SYNTH_REGISTRY)
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            Ressac.register_synth!(Ressac.SynthEntry(:bassline, "p",
                Dict{String,Any}("tags" => ["bass"])))
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["bassline"]
            m.cursor_row = 1
            m.cursor_col = 1
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key("K"))

            play = [Ressac.decode_message(b) for b in mock.sent
                    if Ressac.decode_message(b).address == "/dirt/play"]
            @test length(play) == 1
            @test play[1].args == Any["s", "bassline",
                                       "cut", Int32(Ressac._PREVIEW_CUT_GROUP)]
            @test any(l -> occursin("preview synth bassline", l), m.logs)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            empty!(Ressac._SYNTH_REGISTRY)
        end
    end

    @testset "K resolution: instrument wins over sample" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        empty!(Ressac._SAMPLE_REGISTRY)
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            Ressac.register_instrument!(Ressac.InstrumentEntry(
                :clash, "p",
                Pair{String,Any}["s" => "fromInstrument", "gain" => 2.0],
                Dict{String,Any}(),
            ))
            Ressac.register_sample!(Ressac.SampleEntry(:clash, "p",
                "/tmp/c.wav", ["/tmp/c.wav"], Dict{String,Any}()))
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["clash"]
            m.cursor_row = 1
            m.cursor_col = 1
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key("K"))

            play = [Ressac.decode_message(b) for b in mock.sent
                    if Ressac.decode_message(b).address == "/dirt/play"]
            @test play[1].args == Any["s", "fromInstrument", "gain", Float32(2.0),
                                       "cut", Int32(Ressac._PREVIEW_CUT_GROUP)]
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            empty!(Ressac._INSTRUMENT_REGISTRY)
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset ":samples lists all loaded sample banks" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        try
            Ressac.register_sample!(Ressac.SampleEntry(:bd, "core",
                "/c/bd", ["/c/bd/a.wav"], Dict{String,Any}()))
            Ressac.register_sample!(Ressac.SampleEntry(:kicky, "funkit",
                "/f/k.wav", ["/f/k.wav"],
                Dict{String,Any}("bpm" => 120, "tags" => ["heavy"])))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key(":"))
            for c in "samples"
                Ressac._dispatch_key!(m, _fake_key(string(c)))
            end
            Ressac._dispatch_key!(m, _fake_key("Enter"))
            logs = join(m.logs, "\n")
            @test occursin("bd", logs)
            @test occursin("kicky", logs)
            @test occursin("funkit", logs)
            @test occursin("120 BPM", logs) || occursin("120", logs)
        finally
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset ":samples <glob> filters" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        try
            Ressac.register_sample!(Ressac.SampleEntry(:bd, "p",
                "/x", ["/x"], Dict{String,Any}()))
            Ressac.register_sample!(Ressac.SampleEntry(:bd2, "p",
                "/y", ["/y"], Dict{String,Any}()))
            Ressac.register_sample!(Ressac.SampleEntry(:sn, "p",
                "/z", ["/z"], Dict{String,Any}()))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key(":"))
            for c in "samples bd*"
                Ressac._dispatch_key!(m, _fake_key(string(c)))
            end
            Ressac._dispatch_key!(m, _fake_key("Enter"))
            logs = join(m.logs, "\n")
            @test occursin("bd", logs)
            @test occursin("bd2", logs)
            @test !occursin(r"\bsn\b", logs)
        finally
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset ":samples <name> shows metadata detail" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        try
            Ressac.register_sample!(Ressac.SampleEntry(:kicky, "funkit",
                "/k.wav", ["/k.wav"],
                Dict{String,Any}("bpm" => 120, "key" => "C", "tags" => ["heavy"])))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key(":"))
            for c in "samples kicky"
                Ressac._dispatch_key!(m, _fake_key(string(c)))
            end
            Ressac._dispatch_key!(m, _fake_key("Enter"))
            logs = join(m.logs, "\n")
            @test occursin("kicky", logs)
            @test occursin("bpm", lowercase(logs)) || occursin("BPM", logs)
            @test occursin("heavy", logs)
        finally
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset ":instruments lists all loaded instruments" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        try
            Ressac.register_instrument!(Ressac.InstrumentEntry(
                :kicklourd, "studio",
                Pair{String,Any}["s" => "bd", "gain" => 1.2],
                Dict{String,Any}("tags" => ["heavy"]),
            ))
            Ressac.register_instrument!(Ressac.InstrumentEntry(
                :bassy, "studio",
                Pair{String,Any}["s" => "bassline"],
                Dict{String,Any}(),
            ))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key(":"))
            for c in "instruments"
                Ressac._dispatch_key!(m, _fake_key(string(c)))
            end
            Ressac._dispatch_key!(m, _fake_key("Enter"))
            logs = join(m.logs, "\n")
            @test occursin("kicklourd", logs)
            @test occursin("bassy", logs)
            @test occursin("studio", logs)
            @test occursin("bd", logs)  # s-target shown
            @test occursin("heavy", logs)
        finally
            empty!(Ressac._INSTRUMENT_REGISTRY)
        end
    end

    @testset ":instruments <glob> filters" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        try
            Ressac.register_instrument!(Ressac.InstrumentEntry(
                :kicklourd, "p", Pair{String,Any}["s" => "bd"], Dict{String,Any}()))
            Ressac.register_instrument!(Ressac.InstrumentEntry(
                :kickdoux, "p", Pair{String,Any}["s" => "bd"], Dict{String,Any}()))
            Ressac.register_instrument!(Ressac.InstrumentEntry(
                :bassy, "p", Pair{String,Any}["s" => "bassline"], Dict{String,Any}()))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key(":"))
            for c in "instruments kick*"
                Ressac._dispatch_key!(m, _fake_key(string(c)))
            end
            Ressac._dispatch_key!(m, _fake_key("Enter"))
            logs = join(m.logs, "\n")
            @test occursin("kicklourd", logs)
            @test occursin("kickdoux", logs)
            @test !occursin("bassy", logs)
        finally
            empty!(Ressac._INSTRUMENT_REGISTRY)
        end
    end

    @testset ":instruments <name> shows preset detail" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        try
            Ressac.register_instrument!(Ressac.InstrumentEntry(
                :kicklourd, "studio",
                Pair{String,Any}["s" => "bd", "gain" => 1.2, "lpf" => 200],
                Dict{String,Any}("description" => "the kick that hurts"),
            ))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key(":"))
            for c in "instruments kicklourd"
                Ressac._dispatch_key!(m, _fake_key(string(c)))
            end
            Ressac._dispatch_key!(m, _fake_key("Enter"))
            logs = join(m.logs, "\n")
            @test occursin("kicklourd", logs)
            @test occursin("gain", logs)
            @test occursin("1.2", logs)
            @test occursin("lpf", logs)
            @test occursin("kick that hurts", logs)
        finally
            empty!(Ressac._INSTRUMENT_REGISTRY)
        end
    end

    @testset ":instruments <name> on miss logs WARN" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key(":"))
        for c in "instruments ghost"
            Ressac._dispatch_key!(m, _fake_key(string(c)))
        end
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test any(l -> occursin("no instrument 'ghost'", l), m.logs)
    end

    @testset ":guide opens the modal (mode shift)" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key(":"))
        for c in "guide"
            Ressac._dispatch_key!(m, _fake_key(string(c)))
        end
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test m.mode === :guide
        @test m.guide_scroll == 0
        # Spec sanity: guide content covers the key sections.
        guide_text = join(Ressac._GUIDE_LINES, "\n")
        @test occursin("Ressac guide", guide_text)
        @test occursin("PATTERNS", guide_text)
        @test occursin(":browse", guide_text)
        @test occursin(":synth ", guide_text)
    end

    @testset ":help and :? alias :guide" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key(":"))
        for c in "help"
            Ressac._dispatch_key!(m, _fake_key(string(c)))
        end
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test m.mode === :guide
    end

    @testset ":synths lists all + shows detail" begin
        empty!(Ressac._SYNTH_REGISTRY)
        try
            Ressac.register_synth!(Ressac.SynthEntry(:bassline, "studio",
                Dict{String,Any}("tags" => ["bass"], "description" => "warm sub")))
            Ressac.register_synth!(Ressac.SynthEntry(:pad1, "studio",
                Dict{String,Any}()))

            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key(":"))
            for c in "synths"
                Ressac._dispatch_key!(m, _fake_key(string(c)))
            end
            Ressac._dispatch_key!(m, _fake_key("Enter"))
            logs = join(m.logs, "\n")
            @test occursin("bassline", logs)
            @test occursin("pad1", logs)
            @test occursin("studio", logs)
            @test occursin("bass", logs)

            empty!(m.logs)
            Ressac._dispatch_key!(m, _fake_key(":"))
            for c in "synths bassline"
                Ressac._dispatch_key!(m, _fake_key(string(c)))
            end
            Ressac._dispatch_key!(m, _fake_key("Enter"))
            logs = join(m.logs, "\n")
            @test occursin("warm sub", logs)
        finally
            empty!(Ressac._SYNTH_REGISTRY)
        end
    end

    @testset "Tab in :-mode cycles command-name matches" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key(":"))
        Ressac._dispatch_key!(m, _fake_key("s"))
        Ressac._dispatch_key!(m, _fake_key("a"))
        @test m.command_buffer == "sa"
        Ressac._dispatch_key!(m, _fake_key("Tab"))
        # `samples` and `save` both fuzzy-match "sa"; shorter wins first.
        @test m.command_buffer in ("save", "samples")
        @test !isempty(m.completions)
        before = m.command_buffer
        Ressac._dispatch_key!(m, _fake_key("Tab"))
        @test m.command_buffer != before || length(m.completions) == 1
    end

    @testset "Tab in :-mode with no matches is silent no-op" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key(":"))
        Ressac._dispatch_key!(m, _fake_key("z"))
        Ressac._dispatch_key!(m, _fake_key("z"))
        @test m.command_buffer == "zz"
        Ressac._dispatch_key!(m, _fake_key("Tab"))
        @test m.command_buffer == "zz"
        @test isempty(m.completions)
    end

    @testset "Editing the command buffer clears Tab cycle" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key(":"))
        Ressac._dispatch_key!(m, _fake_key("s"))
        Ressac._dispatch_key!(m, _fake_key("Tab"))
        @test !isempty(m.completions)
        Ressac._dispatch_key!(m, _fake_key("a"))
        @test m.completion_cycle_idx == 0
    end

    @testset "Tab in insert mode completes against registry" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        try
            Ressac.register_sample!(Ressac.SampleEntry(:kicky, "p",
                "/x", ["/x"], Dict{String,Any}()))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :insert
            m.buffer = ["kic"]
            m.cursor_row = 1
            m.cursor_col = 4
            Ressac._dispatch_key!(m, _fake_key("Tab"))
            @test m.buffer[1] == "kicky"
        finally
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset "Tab in insert mode cycles multiple matches" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        try
            Ressac.register_sample!(Ressac.SampleEntry(:kicky, "p",
                "/x", ["/x"], Dict{String,Any}()))
            Ressac.register_sample!(Ressac.SampleEntry(:kicks, "p",
                "/y", ["/y"], Dict{String,Any}()))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :insert
            m.buffer = ["kic"]
            m.cursor_row = 1
            m.cursor_col = 4
            Ressac._dispatch_key!(m, _fake_key("Tab"))
            first_completion = m.buffer[1]
            @test first_completion in ("kicks", "kicky")
            Ressac._dispatch_key!(m, _fake_key("Tab"))
            second_completion = m.buffer[1]
            @test second_completion != first_completion
            @test second_completion in ("kicks", "kicky")
        finally
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset "Tab in insert mode inside mini-notation excludes combinators" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        try
            Ressac.register_sample!(Ressac.SampleEntry(:fastdrum, "p",
                "/x", ["/x"], Dict{String,Any}()))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :insert
            m.buffer = ["p\"fas"]
            m.cursor_row = 1
            m.cursor_col = 6
            Ressac._dispatch_key!(m, _fake_key("Tab"))
            @test m.buffer[1] == "p\"fastdrum"
        finally
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset "Tab in insert mode default context includes combinators" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :insert
        m.buffer = ["@d1 fas"]
        m.cursor_row = 1
        m.cursor_col = 8
        Ressac._dispatch_key!(m, _fake_key("Tab"))
        @test m.buffer[1] == "@d1 fast"
    end

    @testset ":guide switches m.mode to :guide" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key(":"))
        for c in "guide"
            Ressac._dispatch_key!(m, _fake_key(string(c)))
        end
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test m.mode === :guide
        @test m.guide_scroll == 0
    end

    @testset "guide-mode j scrolls down, k scrolls up" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :guide
        m.guide_scroll = 0
        Ressac._dispatch_key!(m, _fake_key("j"))
        @test m.guide_scroll == 1
        Ressac._dispatch_key!(m, _fake_key("j"))
        @test m.guide_scroll == 2
        Ressac._dispatch_key!(m, _fake_key("k"))
        @test m.guide_scroll == 1
    end

    @testset "guide-mode k clamps to 0" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :guide
        m.guide_scroll = 0
        Ressac._dispatch_key!(m, _fake_key("k"))
        @test m.guide_scroll == 0
    end

    @testset "guide-mode gg jumps to top, G to bottom" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :guide
        m.guide_scroll = 5
        Ressac._dispatch_key!(m, _fake_key("g"))
        Ressac._dispatch_key!(m, _fake_key("g"))
        @test m.guide_scroll == 0
        Ressac._dispatch_key!(m, _fake_key("G"))
        @test m.guide_scroll == max(0, length(Ressac._GUIDE_LINES) - 1)
    end

    @testset "guide-mode q returns to normal" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :guide
        Ressac._dispatch_key!(m, _fake_key("q"))
        @test m.mode === :normal
    end

    @testset "guide-mode Esc returns to normal" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :guide
        Ressac._dispatch_key!(m, _fake_key("Esc"))
        @test m.mode === :normal
    end

    @testset "guide-mode / search jumps to first match" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :guide
        m.guide_scroll = 0
        Ressac._dispatch_key!(m, _fake_key("/"))
        @test m.mode === :command
        @test m.command_prefix == '/'
        @test m.guide_search_active == true
        for c in "guide"
            Ressac._dispatch_key!(m, _fake_key(string(c)))
        end
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test m.mode === :guide
        idx = findfirst(l -> occursin("guide", lowercase(l)), Ressac._GUIDE_LINES)
        @test idx !== nothing
        @test m.guide_scroll == idx - 1
        @test m.guide_search_active == false
    end

    @testset "guide-mode / search no match leaves scroll alone" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :guide
        m.guide_scroll = 3
        Ressac._dispatch_key!(m, _fake_key("/"))
        for c in "zzznosuchstring"
            Ressac._dispatch_key!(m, _fake_key(string(c)))
        end
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test m.mode === :guide
        @test m.guide_scroll == 3
    end

    @testset "guide-mode / search Esc returns to guide" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :guide
        m.guide_scroll = 2
        Ressac._dispatch_key!(m, _fake_key("/"))
        for c in "any"
            Ressac._dispatch_key!(m, _fake_key(string(c)))
        end
        Ressac._dispatch_key!(m, _fake_key("Esc"))
        @test m.mode === :guide
        @test m.guide_scroll == 2
        @test m.guide_search_active == false
    end

    @testset "Movement clears insert-mode completion cycle" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        try
            Ressac.register_sample!(Ressac.SampleEntry(:kicky, "p",
                "/x", ["/x"], Dict{String,Any}()))
            Ressac.register_sample!(Ressac.SampleEntry(:kicks, "p",
                "/y", ["/y"], Dict{String,Any}()))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :insert
            m.buffer = ["kic"]
            m.cursor_row = 1
            m.cursor_col = 4
            Ressac._dispatch_key!(m, _fake_key("Tab"))
            @test !isempty(m.completions)
            Ressac._dispatch_key!(m, _fake_key("Left"))
            @test isempty(m.completions)
        finally
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end
end
