using Test
using Ressac

@testset "tui_eval" begin
    @testset "_block_text joins paragraph lines" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["@d1 (",
                    "  pure(:bd)",
                    "  |> fast(2)",
                    ")",
                    "",
                    "@d2 pure(:sn)"]
        m.cursor_row = 2
        text = Ressac._block_text(m)
        @test text == "@d1 (\n  pure(:bd)\n  |> fast(2)\n)"
    end

    @testset "_eval_block! installs the pattern via _route_to_slot!" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=1.0)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["@d1 pure(:bd)"]
            m.cursor_row = 1
            Ressac._eval_block!(m; mode=:immediate, n=0)
            @test haskey(sched.patterns, :d1)
            # last_eval_block records (row_start, row_stop) for the slot.
            @test m.last_eval_block[:d1] == (1, 1)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            Ressac._EVAL_MODE[] = (:immediate, 0)
        end
    end

    @testset "_eval_block! deferred mode queues via schedule_pattern!" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=1.0)
        sched.t_start = time() - 0.5  # cycle ≈ 0.5 → ceil = 1
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["@d1 pure(:bd)"]
            m.cursor_row = 1
            Ressac._eval_block!(m; mode=:deferred, n=2)
            @test !haskey(sched.patterns, :d1)
            @test haskey(sched.pending, :d1)
            (_, at) = sched.pending[:d1]
            @test at == 3 // 1  # ceil(0.5) + 2
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            Ressac._EVAL_MODE[] = (:immediate, 0)
        end
    end

    @testset "_eval_block! on blank-line cursor is a no-op" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=1.0)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["@d1 pure(:bd)", "", "@d2 pure(:sn)"]
            m.cursor_row = 2
            Ressac._eval_block!(m; mode=:immediate, n=0)
            @test !haskey(sched.patterns, :d1)
            @test !haskey(sched.patterns, :d2)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "_eval_block! logs errors to m.logs without throwing" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=1.0)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["this is not valid Julia ((("]
            m.cursor_row = 1
            Ressac._eval_block!(m; mode=:immediate, n=0)
            @test any(l -> occursin("ERROR", l), m.logs)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end
end
