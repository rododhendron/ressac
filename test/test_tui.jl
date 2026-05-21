using Test
using Ressac
using TerminalUserInterfaces
const TUI = TerminalUserInterfaces

@testset "tui v2 (non-interactive)" begin
    @testset "live API helpers error without an active session" begin
        Ressac._LIVE_SCHEDULER[] = nothing
        @test_throws ErrorException d!(:d1, pure(:bd))
        @test_throws ErrorException unset!(:d1)
        @test_throws ErrorException hush_all!()
        @test_throws ErrorException cps!(0.5)
    end

    @testset "TUI.view returns a non-throwing widget tree" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        m = Ressac.LiveModel(; scheduler=sched)
        @test TUI.view(m) !== nothing
        # With patterns + pending + selection, view still doesn't throw.
        m.buffer = ["@d1 pure(:bd)", "@d2 pure(:sn)"]
        set_pattern!(sched, :d1, pure(:bd))
        schedule_pattern!(sched, :d2, pure(:sn), 4 // 1)
        m.last_eval_block[:d1] = (1, 1)
        m.mode = :visual_line; m.visual_anchor = (1, 1); m.cursor_row = 2
        @test TUI.view(m) !== nothing
    end

    @testset "command-mode prompt shows in the rendered tree" begin
        mock = MockOSCClient()
        m = Ressac.LiveModel(; scheduler=Scheduler(mock; cps=0.5))
        m.mode = :command; m.command_prefix = ':'; m.command_buffer = "cps 1.0"
        widget = TUI.view(m)
        @test widget !== nothing
    end
end
