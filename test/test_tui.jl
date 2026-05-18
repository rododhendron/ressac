using Test
using Ressac
using TerminalUserInterfaces
const TUI = TerminalUserInterfaces

@testset "tui (non-interactive)" begin
    @testset "d! / hush_all! / cps! error when no live session is active" begin
        # Make sure no leftover session from another test.
        Ressac._LIVE_SCHEDULER[] = nothing
        @test_throws ErrorException d!(:d1, pure(:bd))
        @test_throws ErrorException hush_all!()
        @test_throws ErrorException cps!(0.5)
    end

    @testset "LiveModel constructs and produces a view widget tree" begin
        mock = MockOSCClient()  # defined in test_scheduler.jl
        sched = Scheduler(mock; cps=0.5)
        m = Ressac.LiveModel(; scheduler=sched)
        # Just verify view runs without throwing — content is rendered by TUI.app.
        widget = TUI.view(m)
        @test widget !== nothing
    end

    @testset "_eval_input! pushes successful evaluations to history" begin
        mock = MockOSCClient()
        sched = Scheduler(mock)
        m = Ressac.LiveModel(; scheduler=sched)
        m.input = "1 + 1"
        Ressac._eval_input!(m)
        @test length(m.history) == 1
        @test occursin("2", m.history[end])
        @test isempty(m.input)
    end

    @testset "_eval_input! routes parse/runtime errors to logs" begin
        mock = MockOSCClient()
        sched = Scheduler(mock)
        m = Ressac.LiveModel(; scheduler=sched)
        m.input = "this is not valid Julia ((("
        Ressac._eval_input!(m)
        @test length(m.logs) >= 1
        @test occursin("ERROR", m.logs[end])
    end

    @testset "blank input is a no-op" begin
        mock = MockOSCClient()
        sched = Scheduler(mock)
        m = Ressac.LiveModel(; scheduler=sched)
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
end
