using Test
using Ressac

@testset "live_api" begin
    @testset "_route_to_slot! immediate mode delegates to set_pattern!" begin
        _with_test_scheduler(cps = 1.0) do mock, sched
            Ressac._EVAL_MODE[] = (:immediate, 0)
            Ressac._route_to_slot!(:d1, pure(:bd))
            @test haskey(sched.patterns, :d1)
            @test !haskey(sched.pending, :d1)
        end
        Ressac._EVAL_MODE[] = (:immediate, 0)
    end

    @testset "_route_to_slot! deferred mode delegates to schedule_pattern!" begin
        _with_test_scheduler(cps = 1.0) do mock, sched
            # Set t_start 0.5 s in the past → current_cycle ≈ 0.5
            sched.t_start = time() - 0.5
            Ressac._EVAL_MODE[] = (:deferred, 2)
            Ressac._route_to_slot!(:d1, pure(:bd))
            @test !haskey(sched.patterns, :d1)
            @test haskey(sched.pending, :d1)
            (_, at) = sched.pending[:d1]
            # current_cycle ≈ 0.5, ceil(0.5) = 1, target = 1 + 2 = 3.
            @test at == 3 // 1
        end
        Ressac._EVAL_MODE[] = (:immediate, 0)
    end

    @testset "_route_to_slot! with no body unsets the slot" begin
        _with_test_scheduler(cps = 1.0) do mock, sched
            set_pattern!(sched, :d1, pure(:bd))
            Ressac._route_to_slot!(:d1)
            @test !haskey(sched.patterns, :d1)
        end
    end

    @testset "@d1 macro expands to _route_to_slot!(:d1, body)" begin
        # macroexpand returns the unescaped expression.
        ex = @macroexpand @d1 pure(:bd)
        # Look for a call to _route_to_slot! with :d1 as the first arg.
        @test ex isa Expr && ex.head === :call
        @test ex.args[1] === :(Ressac._route_to_slot!) || ex.args[1] === :_route_to_slot! ||
              ex.args[1] == GlobalRef(Ressac, :_route_to_slot!)
        @test ex.args[2] === :(:d1) || ex.args[2] === QuoteNode(:d1)
    end

    @testset "@d3 with no body unsets the slot" begin
        _with_test_scheduler(cps = 1.0) do mock, sched
            set_pattern!(sched, :d3, pure(:bd))
            Core.eval(Main, :(@d3))
            @test !haskey(sched.patterns, :d3)
        end
    end

    @testset "@d64 is the highest slot" begin
        @test isdefined(Ressac, Symbol("@d64"))
        @test !isdefined(Ressac, Symbol("@d65"))
    end
end
