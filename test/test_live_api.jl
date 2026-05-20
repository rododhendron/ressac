using Test
using Ressac

@testset "live_api" begin
    @testset "_route_to_slot! immediate mode delegates to set_pattern!" begin
        mock = MockOSCClient()  # from test_scheduler.jl
        sched = Scheduler(mock; cps=1.0)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            Ressac._EVAL_MODE[] = (:immediate, 0)
            Ressac._route_to_slot!(:d1, pure(:bd))
            @test haskey(sched.patterns, :d1)
            @test !haskey(sched.pending, :d1)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            Ressac._EVAL_MODE[] = (:immediate, 0)
        end
    end

    @testset "_route_to_slot! deferred mode delegates to schedule_pattern!" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=1.0)
        # Set t_start 0.5 s in the past → current_cycle ≈ 0.5 (cps=1.0)
        # ceil(0.5) = 1, so target = 1 + 2 = 3.
        sched.t_start = time() - 0.5
        Ressac._LIVE_SCHEDULER[] = sched
        try
            Ressac._EVAL_MODE[] = (:deferred, 2)
            Ressac._route_to_slot!(:d1, pure(:bd))
            @test !haskey(sched.patterns, :d1)
            @test haskey(sched.pending, :d1)
            (_, at) = sched.pending[:d1]
            # current_cycle ≈ 0.5, ceil(0.5) = 1, target = 1 + 2 = 3.
            @test at == 3 // 1
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            Ressac._EVAL_MODE[] = (:immediate, 0)
        end
    end

    @testset "_route_to_slot! with no body unsets the slot" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=1.0)
        set_pattern!(sched, :d1, pure(:bd))
        Ressac._LIVE_SCHEDULER[] = sched
        try
            Ressac._route_to_slot!(:d1)
            @test !haskey(sched.patterns, :d1)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end
end
