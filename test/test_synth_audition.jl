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
        @test st.defined_gen == -1
    end

    @testset "enqueue_generation! defines every candidate (N msgs)" begin
        st = Ressac.AuditionState(3)
        osc = MockOSCClient()
        genomes = [base(), base(), base()]
        Ressac.enqueue_generation!(st, osc, genomes)
        @test length(osc.sent) == 3
    end

    @testset "audition_play! plays a pre-defined synth via /ressac/play" begin
        st = Ressac.AuditionState(3)
        osc = MockOSCClient()
        Ressac.audition_play!(st, osc, 2, 220.0, 0.5)
        @test length(osc.sent) == 1
        # second play does NOT redefine (no evalAndPlay) — just plays again
        Ressac.audition_play!(st, osc, 2, 330.0, 0.5)
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

@testset "SC synth-error feedback → app log" begin
    @testset "_handle_synth_error! pushes a [SC ERROR] line to the log" begin
        log = Ressac._APP_LOG[]
        n0 = length(log)
        Ressac._handle_synth_error!(Any["ga_slot5", "RLPF first input is not audio rate"])
        @test length(log) == n0 + 1
        @test occursin("[SC ERROR]", log[end])
        @test occursin("ga_slot5", log[end])
        @test occursin("audio rate", log[end])
    end

    @testset "tolerates missing args" begin
        log = Ressac._APP_LOG[]
        Ressac._handle_synth_error!(Any[])
        @test occursin("[SC ERROR]", log[end])
    end
end
