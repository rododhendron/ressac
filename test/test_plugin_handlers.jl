using Test
using Ressac

@testset "plugin_handlers" begin
    @testset "[julia] handler includes each file into Main" begin
        Main.eval(:(_ressac_jul_hook_loaded = false))
        m = Ressac.parse_manifest(joinpath(@__DIR__, "fixtures", "plugins", "jul"))
        h = Ressac.get_section_handler(:julia)
        @test h !== nothing
        h(m.dir, m.sections["julia"], m.name)
        @test Main._ressac_jul_hook_loaded === true
    end

    @testset "[julia] missing file logs error, does not throw" begin
        h = Ressac.get_section_handler(:julia)
        @test_logs (:error, r"no such file|missing") match_mode=:any begin
            h("/nonexistent", Dict("files" => ["./nope.jl"]), "nope")
        end
    end

    @testset "[samples] handler sends /dirt/loadSampleFolder per root" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.parse_manifest(joinpath(@__DIR__, "fixtures", "plugins", "withsamples"))
            h = Ressac.get_section_handler(:samples)
            @test h !== nothing
            h(m.dir, m.sections["samples"], m.name)
            @test length(mock.sent) == 1
            msg = Ressac.decode_message(mock.sent[1])
            @test msg.address == "/dirt/loadSampleFolder"
            @test length(msg.args) == 1
            sent_path = msg.args[1]
            @test isabspath(sent_path)
            @test endswith(sent_path, "/withsamples/samples")
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "[samples] missing root logs error" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            h = Ressac.get_section_handler(:samples)
            @test_logs (:error, r"not found|no such") match_mode=:any begin
                h("/tmp", Dict("roots" => ["./does-not-exist"]), "ghost")
            end
            @test isempty(mock.sent)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "[samples] without active scheduler logs error" begin
        Ressac._LIVE_SCHEDULER[] = nothing
        h = Ressac.get_section_handler(:samples)
        @test_logs (:error, r"no active") match_mode=:any begin
            h("/tmp", Dict("roots" => ["./samples"]), "ghost")
        end
    end

    @testset "[synthdefs] handler sends /dirt/evalSC with file content" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.parse_manifest(joinpath(@__DIR__, "fixtures", "plugins", "withsynth"))
            h = Ressac.get_section_handler(:synthdefs)
            @test h !== nothing
            h(m.dir, m.sections["synthdefs"], m.name)
            @test length(mock.sent) == 1
            msg = Ressac.decode_message(mock.sent[1])
            @test msg.address == "/dirt/evalSC"
            @test length(msg.args) == 1
            @test occursin("SynthDef", msg.args[1])
            @test occursin("bassline", msg.args[1])
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "[synthdefs] missing file logs error" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            h = Ressac.get_section_handler(:synthdefs)
            @test_logs (:error, r"not found|no such") match_mode=:any begin
                h("/tmp", Dict("files" => ["./nope.scd"]), "ghost")
            end
            @test isempty(mock.sent)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end
end
