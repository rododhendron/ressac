using Test
using Ressac

# Test-only OSC sink: records every byte payload that the scheduler sends,
# so we can assert on counts and contents without a live UDP socket.
mutable struct MockOSCClient
    sent::Vector{Vector{UInt8}}
end
MockOSCClient() = MockOSCClient(Vector{UInt8}[])
Ressac.send_osc(c::MockOSCClient, bytes::Vector{UInt8}) = push!(c.sent, bytes)

@testset "scheduler" begin
    @testset "_step! sends one bundle per event in the new window" begin
        mock = MockOSCClient()
        s = Scheduler(mock; cps=1.0, lookahead=0.05)
        set_pattern!(s, :d1, pure(:bd))
        s.t_start = 0.0
        # First step: window [0, 0.05) cycles. pure(:bd) yields one clipped event.
        Ressac._step!(s, 0.0)
        @test length(mock.sent) == 1
    end

    @testset "no double-fire across consecutive _step!s" begin
        mock = MockOSCClient()
        s = Scheduler(mock; cps=10.0, lookahead=0.1)
        # fast(4, pure(:bd)): 4 events per cycle.
        set_pattern!(s, :d1, fast(4, pure(:bd)))
        s.t_start = 0.0
        Ressac._step!(s, 0.0)   # window [0,   1.0) cycles → 4 events
        Ressac._step!(s, 0.05)  # window [1.0, 1.5) cycles → 2 events
        Ressac._step!(s, 0.10)  # window [1.5, 2.0) cycles → 2 events
        @test length(mock.sent) == 8
    end

    @testset "multiple slots are all queried" begin
        mock = MockOSCClient()
        s = Scheduler(mock; cps=1.0, lookahead=0.05)
        set_pattern!(s, :d1, pure(:bd))
        set_pattern!(s, :d2, pure(:sn))
        s.t_start = 0.0
        Ressac._step!(s, 0.0)
        @test length(mock.sent) == 2
    end

    @testset "set_pattern! / hush! / set_cps!" begin
        mock = MockOSCClient()
        s = Scheduler(mock)
        set_pattern!(s, :d1, pure(:bd))
        set_pattern!(s, :d2, pure(:sn))
        @test length(s.patterns) == 2

        hush!(s)
        @test isempty(s.patterns)

        set_cps!(s, 0.75)
        @test s.cps == 0.75
        @test_throws ArgumentError set_cps!(s, 0.0)
        @test_throws ArgumentError set_cps!(s, -1.0)
    end

    @testset "event_to_osc default: Event{Symbol} → /dirt/play" begin
        msg = Ressac.event_to_osc(Event(0//1, 1//1, :bd))
        @test msg.address == "/dirt/play"
        @test msg.args == Any["s", "bd"]
    end

    @testset "event_to_osc errors for unmapped types" begin
        @test_throws ArgumentError Ressac.event_to_osc(Event(0//1, 1//1, 42))
    end

    @testset "start! / stop! exits cleanly" begin
        mock = MockOSCClient()
        s = Scheduler(mock; cps=4.0, lookahead=0.02)
        set_pattern!(s, :d1, pure(:bd))
        start!(s)
        sleep(0.15)
        stop!(s)
        sleep(0.1)  # give the loop a moment to observe the flag
        @test s.running[] == false
        @test length(mock.sent) > 0
    end
end
