include(joinpath(@__DIR__, "helpers.jl"))
using Test
using Ressac

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
    # L'erreur arrive sur le thread d'écoute OSC : elle passe par la file
    # des notices, que la vue verse dans le journal à la frame suivante.
    @testset "_handle_synth_error! dépose une ligne [SC ERROR] pour le journal" begin
        Ressac._drain_notices!()
        Ressac._handle_synth_error!(Any["ga_slot5", "RLPF first input is not audio rate"])
        lines = Ressac._drain_notices!()
        @test length(lines) == 1
        @test occursin("[SC ERROR]", lines[1])
        @test occursin("ga_slot5", lines[1])
        @test occursin("audio rate", lines[1])
    end

    @testset "tolerates missing args" begin
        Ressac._handle_synth_error!(Any[])
        @test occursin("[SC ERROR]", only(Ressac._drain_notices!()))
    end

    @testset "la vue verse les notices dans le journal" begin
        app, frame = _new_app()
        Ressac._handle_synth_error!(Any["zz", "boom"])
        Tachikoma.view(app, frame)
        @test any(l -> occursin("[SC ERROR] synth zz: boom", l), app.logs)
    end
end
