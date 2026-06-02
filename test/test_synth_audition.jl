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

@testset "RMS level feedback → silence flag" begin
    @testset "level probe is baked into ga_slotN synthdefs only" begin
        g = Ressac.archetype(:drone_grave)
        @test occursin("SendReply.kr(Impulse.kr(15), '/ressac/level', [5,", Ressac.render_synthdef(g, :ga_slot5))
        @test !occursin("/ressac/level", Ressac.render_synthdef(g, :x))    # export name → no probe
    end

    @testset "_handle_synth_level! stores the peak per slot" begin
        Ressac._reset_slot_levels!(9)
        Ressac._handle_synth_level!(Any[1200, 3, 4, 0.42])   # nodeID, replyID, slot=4, amp
        @test Ressac._GA_SLOT_LEVEL[][4] ≈ 0.42f0
        @test Ressac._GA_SLOT_MEASURED[][4]
        Ressac._handle_synth_level!(Any[1200, 3, 4, 0.10])   # lower → peak unchanged
        @test Ressac._GA_SLOT_LEVEL[][4] ≈ 0.42f0
    end

    @testset "enqueue resets levels" begin
        Ressac._handle_synth_level!(Any[1, 1, 2, 0.5])
        st = Ressac.AuditionState(9)
        Ressac.enqueue_generation!(st, MockOSCClient(),
                                   [Ressac.archetype(:pluck) for _ in 1:9])
        @test all(==(0.0f0), Ressac._GA_SLOT_LEVEL[])
        @test !any(Ressac._GA_SLOT_MEASURED[])
    end
end
