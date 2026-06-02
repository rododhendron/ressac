using Test
using Ressac

if !isdefined(Main, :MockOSCClient)
    mutable struct MockOSCClient
        sent::Vector{Vector{UInt8}}
    end
    MockOSCClient() = MockOSCClient(Vector{UInt8}[])
    Ressac.send_osc(c::MockOSCClient, bytes::Vector{UInt8}) = push!(c.sent, bytes)
end

@testset "synth_audition" begin
    base() = Ressac.archetype(:pluck)

    @testset "state has a bounded slot-name pool" begin
        st = Ressac.AuditionState(9)
        @test length(st.slot_names) == 9
        @test st.slot_names[1] === Symbol("ga_slot1")
        @test all(!, st.played_once)
    end

    @testset "play address: first = evalAndPlay, then play" begin
        st = Ressac.AuditionState(9)
        @test Ressac._audition_play_address(st, 3) === :evalAndPlay
        st.played_once[3] = true
        @test Ressac._audition_play_address(st, 3) === :play
    end

    @testset "enqueue_generation! defines every candidate (N msgs)" begin
        st = Ressac.AuditionState(3)
        osc = MockOSCClient()
        genomes = [base(), base(), base()]
        Ressac.enqueue_generation!(st, osc, genomes)
        @test length(osc.sent) == 3
        @test all(!, st.played_once)
    end

    @testset "audition_play! sends one message + flips played_once" begin
        st = Ressac.AuditionState(3)
        osc = MockOSCClient()
        Ressac.audition_play!(st, osc, 2, base(), 220.0, 0.5)
        @test length(osc.sent) == 1
        @test st.played_once[2]
        Ressac.audition_play!(st, osc, 2, base(), 330.0, 0.5)
        @test length(osc.sent) == 2
    end

    @testset "hold promotes to ga_held, stop clears it" begin
        st = Ressac.AuditionState(3)
        osc = MockOSCClient()
        Ressac.audition_hold!(st, osc, base(), 110.0, 8.0)
        @test st.held_active
        Ressac.audition_stop!(st, osc)
        @test !st.held_active
    end

    @testset "regenerating reuses the same 9 names (no leak)" begin
        st = Ressac.AuditionState(9)
        osc = MockOSCClient()
        for _ in 1:5
            Ressac.enqueue_generation!(st, osc, [base() for _ in 1:9])
        end
        @test length(st.slot_names) == 9
        @test length(unique(st.slot_names)) == 9
    end
end
