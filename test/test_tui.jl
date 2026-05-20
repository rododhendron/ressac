using Test
using Ressac
using TerminalUserInterfaces
const TUI = TerminalUserInterfaces

@testset "tui (non-interactive)" begin
    @testset "d! / unset! / hush_all! / cps! error when no live session is active" begin
        # Make sure no leftover session from another test.
        Ressac._LIVE_SCHEDULER[] = nothing
        @test_throws ErrorException d!(:d1, pure(:bd))
        @test_throws ErrorException unset!(:d1)
        @test_throws ErrorException hush_all!()
        @test_throws ErrorException cps!(0.5)
    end

    @testset "unset! removes a single slot in the active session" begin
        mock = MockOSCClient()
        sched = Scheduler(mock)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            d!(:d1, pure(:bd))
            d!(:d2, pure(:sn))
            unset!(:d1)
            @test !haskey(sched.patterns, :d1)
            @test haskey(sched.patterns, :d2)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "LiveModel constructs and produces a view widget tree" begin
        mock = MockOSCClient()  # defined in test_scheduler.jl
        sched = Scheduler(mock; cps=0.5)
        m = Ressac.LiveModelV1(; scheduler=sched)
        # Just verify view runs without throwing — content is rendered by TUI.app.
        widget = TUI.view(m)
        @test widget !== nothing
    end

    @testset "_eval_input! pushes successful evaluations to history" begin
        mock = MockOSCClient()
        sched = Scheduler(mock)
        m = Ressac.LiveModelV1(; scheduler=sched)
        m.input = "1 + 1"
        Ressac._eval_input!(m)
        @test length(m.history) == 1
        @test occursin("2", m.history[end])
        @test isempty(m.input)
    end

    @testset "_eval_input! routes parse/runtime errors to logs" begin
        mock = MockOSCClient()
        sched = Scheduler(mock)
        m = Ressac.LiveModelV1(; scheduler=sched)
        m.input = "this is not valid Julia ((("
        Ressac._eval_input!(m)
        @test length(m.logs) >= 1
        @test occursin("ERROR", m.logs[end])
    end

    @testset "blank input is a no-op" begin
        mock = MockOSCClient()
        sched = Scheduler(mock)
        m = Ressac.LiveModelV1(; scheduler=sched)
        m.input = "   "
        Ressac._eval_input!(m)
        @test isempty(m.history)
        @test isempty(m.logs)
    end

    @testset "live() helpers route to active scheduler when set" begin
        mock = MockOSCClient()
        sched = Scheduler(mock)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            d!(:d1, pure(:bd))
            @test haskey(sched.patterns, :d1)
            cps!(0.75)
            @test sched.cps == 0.75
            hush_all!()
            @test isempty(sched.patterns)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    # ------------------------------------------------------------------
    # End-to-end: drive the same code path the TUI uses (parse → eval in
    # Main → d! → set_pattern! → _step! → OSC bundle). Single-threaded.
    # ------------------------------------------------------------------
    @testset "e2e: TUI eval of d!(...) installs the pattern" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=1.0)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            ex = Meta.parse("d!(:d1, p\"bd hh sn hh\")")
            result = Core.eval(Main, ex)
            @test result === nothing
            @test haskey(sched.patterns, :d1)
            @test length(sched.patterns) == 1
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "e2e: _step! after eval ships /dirt/play OSC bundles" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=1.0, lookahead=0.05)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            Core.eval(Main, Meta.parse("d!(:d1, pure(:bd))"))
            sched.t_start = 0.0
            Ressac._step!(sched, 0.0)
            @test !isempty(mock.sent)
            # Bundle layout: "#bundle\0" (8) + NTP time tag (8) + Int32 size (4) + inner message.
            bytes = mock.sent[1]
            msg = Ressac.decode_message(bytes[21:end])
            @test msg.address == "/dirt/play"
            @test msg.args == Any["s", "bd"]
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "e2e: LiveModel._eval_input! is the TUI's exact path" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=1.0)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.LiveModelV1(; scheduler=sched)
            m.input = "d!(:d1, p\"bd hh sn hh\")"
            Ressac._eval_input!(m)
            @test haskey(sched.patterns, :d1)
            @test occursin("nothing", m.history[end])
            @test isempty(m.input)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "e2e: status_line reflects mutations done through d!" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.LiveModelV1(; scheduler=sched)
            @test occursin("slots:—", Ressac._status_line(m))
            Core.eval(Main, Meta.parse("d!(:d1, p\"bd\")"))
            @test occursin("d1", Ressac._status_line(m))
            Core.eval(Main, Meta.parse("d!(:d2, p\"sn\")"))
            line = Ressac._status_line(m)
            @test occursin("d1", line) && occursin("d2", line)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end
end
