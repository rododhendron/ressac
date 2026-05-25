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
        _with_test_scheduler() do mock, sched
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
        end
    end

    @testset "[samples] missing root logs error" begin
        _with_test_scheduler() do mock, sched
            h = Ressac.get_section_handler(:samples)
            @test_logs (:error, r"not found|no such") match_mode=:any begin
                h("/tmp", Dict("roots" => ["./does-not-exist"]), "ghost")
            end
            @test isempty(mock.sent)
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
        _with_test_scheduler() do mock, sched
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
        end
    end

    @testset "[synthdefs] missing file logs error" begin
        _with_test_scheduler() do mock, sched
            h = Ressac.get_section_handler(:synthdefs)
            @test_logs (:error, r"not found|no such") match_mode=:any begin
                h("/tmp", Dict("files" => ["./nope.scd"]), "ghost")
            end
            # Critically: /tmp has no plugin.toml, so orphan auto-discovery
            # must NOT scan it. Otherwise we'd glob whoever's test fixtures
            # or stray .jl files live in /tmp and Core.eval them. The
            # guard is `isfile(plugin_dir/plugin.toml)`.
            @test isempty(mock.sent)
        end
    end

    @testset "_audio_files_in returns sorted wav/aiff/flac, skips others" begin
        mktempdir() do d
            for f in ["b.wav", "a.wav", "x.txt", "c.aiff", "d.flac", "skip.ds_store"]
                touch(joinpath(d, f))
            end
            files = Ressac._audio_files_in(d)
            @test basename.(files) == ["a.wav", "b.wav", "c.aiff", "d.flac"]
            @test all(isabspath, files)
        end
    end

    @testset "_audio_files_in missing dir returns empty" begin
        @test isempty(Ressac._audio_files_in("/no/such/path"))
    end

    @testset "[samples.bank] populates registry — file entry" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        _with_test_scheduler() do mock, sched
            m = Ressac.parse_manifest(joinpath(@__DIR__, "fixtures", "plugins", "withbanks"))
            h = Ressac.get_section_handler(:samples)
            h(m.dir, m.sections["samples"], m.name)

            ent = Ressac.sample_info(:kicky)
            @test ent !== nothing
            @test ent.plugin == "withbanks"
            @test length(ent.variants) == 1
            @test endswith(ent.variants[1], "/curated/kicks/heavy_v3.wav")
            @test ent.metadata["bpm"] == 120
            @test ent.metadata["tags"] == ["heavy", "subby"]
        end
        empty!(Ressac._SAMPLE_REGISTRY)
    end

    @testset "[samples.bank] populates registry — directory entry, sorted variants" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        _with_test_scheduler() do mock, sched
            m = Ressac.parse_manifest(joinpath(@__DIR__, "fixtures", "plugins", "withbanks"))
            h = Ressac.get_section_handler(:samples)
            h(m.dir, m.sections["samples"], m.name)

            ent = Ressac.sample_info(:snares)
            @test ent !== nothing
            @test length(ent.variants) == 2
            @test basename.(ent.variants) == ["s1.wav", "s2.wav"]
            @test ent.metadata["tags"] == ["acoustic"]
        end
        empty!(Ressac._SAMPLE_REGISTRY)
    end

    @testset "[samples.bank] sends /dirt/registerSample per bank entry" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        _with_test_scheduler() do mock, sched
            m = Ressac.parse_manifest(joinpath(@__DIR__, "fixtures", "plugins", "withbanks"))
            h = Ressac.get_section_handler(:samples)
            h(m.dir, m.sections["samples"], m.name)

            register_msgs = [Ressac.decode_message(b) for b in mock.sent
                             if Ressac.decode_message(b).address == "/dirt/registerSample"]
            names_sent = sort([msg.args[1] for msg in register_msgs])
            @test names_sent == ["kicky", "snares"]
            kicky = only(filter(m -> m.args[1] == "kicky", register_msgs))
            @test endswith(kicky.args[2], "/curated/kicks/heavy_v3.wav")
            @test isabspath(kicky.args[2])
        end
        empty!(Ressac._SAMPLE_REGISTRY)
    end

    @testset "_osc_value type conversions" begin
        @test Ressac._osc_value(Int64(3))    === Int32(3)
        @test Ressac._osc_value(Int32(3))    === Int32(3)
        @test Ressac._osc_value(Float64(1.2)) === Float32(1.2)
        @test Ressac._osc_value(Float32(1.5)) === Float32(1.5)
        @test Ressac._osc_value("bd")        == "bd"
        @test Ressac._osc_value(true)        === Int32(1)
        @test Ressac._osc_value(false)       === Int32(0)
    end

    @testset "_osc_value warns + returns missing for unsupported types" begin
        result = @test_logs (:warn, r"unsupported OSC value") match_mode=:any begin
            Ressac._osc_value(Dict("x" => 1))
        end
        @test result === missing
    end

    @testset "[instruments] handler populates registry — preserves param order" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        m = Ressac.parse_manifest(joinpath(@__DIR__, "fixtures", "plugins", "withinst"))
        h = Ressac.get_section_handler(:instruments)
        @test h !== nothing
        h(m.dir, m.sections["instruments"], m.name)

        kick = Ressac.instrument_info(:kicklourd)
        @test kick !== nothing
        @test kick.plugin == "withinst"
        @test kick.params[1] == ("s" => "bd")
        param_keys = [p.first for p in kick.params]
        @test "s" in param_keys && "n" in param_keys && "gain" in param_keys && "lpf" in param_keys
        @test param_keys[1] == "s"
        @test kick.metadata["tags"] == ["heavy", "subby"]
        @test kick.metadata["description"] == "the kick that hurts"

        bassy = Ressac.instrument_info(:bassy)
        @test bassy.params[1] == ("s" => "bassline")
        @test isempty(bassy.metadata)
        empty!(Ressac._INSTRUMENT_REGISTRY)
    end

    @testset "[instruments] missing 's' key logs error, skips entry" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        h = Ressac.get_section_handler(:instruments)
        @test_logs (:error, r"kicklourd.*missing.*s") match_mode=:any begin
            h("/tmp",
              Dict("kicklourd" => Dict{String,Any}("gain" => 1.0)),
              "ghost")
        end
        @test Ressac.instrument_info(:kicklourd) === nothing
        empty!(Ressac._INSTRUMENT_REGISTRY)
    end

    @testset "[synths] handler populates registry with metadata" begin
        empty!(Ressac._SYNTH_REGISTRY)
        m = Ressac.parse_manifest(joinpath(@__DIR__, "fixtures", "plugins", "withinst"))
        h = Ressac.get_section_handler(:synths)
        @test h !== nothing
        h(m.dir, m.sections["synths"], m.name)

        ent = Ressac.synth_info(:bassline)
        @test ent !== nothing
        @test ent.plugin == "withinst"
        @test ent.metadata["tags"] == ["bass", "low"]
        @test ent.metadata["description"] == "warm sub bass"
        empty!(Ressac._SYNTH_REGISTRY)
    end

    @testset "[synths] non-table body logs error, skips entry" begin
        empty!(Ressac._SYNTH_REGISTRY)
        h = Ressac.get_section_handler(:synths)
        @test_logs (:error, r"synths.bogus.*must be a table") match_mode=:any begin
            h("/tmp", Dict("bogus" => "not a table"), "ghost")
        end
        @test Ressac.synth_info(:bogus) === nothing
        empty!(Ressac._SYNTH_REGISTRY)
    end

    @testset "[samples].roots still sends /dirt/loadSampleFolder (back-compat)" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        _with_test_scheduler() do mock, sched
            m = Ressac.parse_manifest(joinpath(@__DIR__, "fixtures", "plugins", "withsamples"))
            h = Ressac.get_section_handler(:samples)
            h(m.dir, m.sections["samples"], m.name)

            addrs = [Ressac.decode_message(b).address for b in mock.sent]
            @test "/dirt/loadSampleFolder" in addrs
        end
        empty!(Ressac._SAMPLE_REGISTRY)
    end

    # ── Orphan auto-discovery for [synthdefs] ──────────────────────
    # When a plugin's user has saved a synth file (.scd or .jl) but
    # didn't update the manifest, `_handle_synthdefs` should glob the
    # plugin dir and load it anyway. Required guards:
    #   1. Skip if plugin_dir has no plugin.toml (defends synthetic
    #      test paths like /tmp from being globbed + Core.eval'd).
    #   2. Skip files that don't sniff as synth source.

    @testset "_looks_like_synth_source — header sniff" begin
        mktempdir() do d
            ok_scd   = joinpath(d, "ok.scd")
            ok_jl    = joinpath(d, "ok.jl")
            bad_scd  = joinpath(d, "bad.scd")
            bad_jl   = joinpath(d, "bad.jl")
            wrong    = joinpath(d, "ok.txt")
            write(ok_scd,  "SynthDef(\\foo, { ... }).add;")
            write(ok_jl,   "@synth :bar saw(:freq)")
            write(bad_scd, "// just a comment")
            write(bad_jl,  "println(\"hi\")")
            write(wrong,   "SynthDef(\\foo, ...)")  # wrong ext

            @test Ressac._looks_like_synth_source(ok_scd)
            @test Ressac._looks_like_synth_source(ok_jl)
            @test !Ressac._looks_like_synth_source(bad_scd)
            @test !Ressac._looks_like_synth_source(bad_jl)
            @test !Ressac._looks_like_synth_source(wrong)
            # Unreadable / missing path → false (no crash).
            @test !Ressac._looks_like_synth_source(joinpath(d, "nope.scd"))
        end
    end

    @testset "[synthdefs] orphan auto-discovery requires plugin.toml" begin
        _with_test_scheduler() do mock, sched
            h = Ressac.get_section_handler(:synthdefs)
            mktempdir() do d
                # Real-looking SCD file in a dir WITHOUT plugin.toml.
                # The guard must skip orphan discovery so this file
                # is not loaded.
                write(joinpath(d, "stray.scd"), "SynthDef(\\stray, ...).add;")
                h(d, Dict("files" => String[]), "ghostly")
                @test isempty(mock.sent)
            end
        end
    end

    @testset "[synthdefs] orphan auto-discovery picks up unmanifested .scd" begin
        _with_test_scheduler() do mock, sched
            h = Ressac.get_section_handler(:synthdefs)
            mktempdir() do d
                touch(joinpath(d, "plugin.toml"))  # satisfies the guard
                write(joinpath(d, "claimed.scd"),  "SynthDef(\\claimed, {Out.ar(0, Silent.ar)}).add;")
                write(joinpath(d, "orphan.scd"),   "SynthDef(\\orphan, {Out.ar(0, Silent.ar)}).add;")
                write(joinpath(d, "ignore_me.scd"),"// not a synthdef, no header")
                h(d, Dict("files" => ["./claimed.scd"]), "myplug")
                # Both real SCDs ship via /dirt/evalSC (manifested + orphan).
                # The non-sniffing file is skipped.
                @test length(mock.sent) == 2
                addrs = [Ressac.decode_message(b).address for b in mock.sent]
                @test all(==("/dirt/evalSC"), addrs)
            end
        end
    end

    @testset "[synthdefs] orphan auto-discovery registers SynthEntry" begin
        empty!(Ressac._SYNTH_REGISTRY)
        _with_test_scheduler() do mock, sched
            h = Ressac.get_section_handler(:synthdefs)
            mktempdir() do d
                touch(joinpath(d, "plugin.toml"))
                write(joinpath(d, "auto.scd"), "SynthDef(\\auto, {Out.ar(0, Silent.ar)}).add;")
                h(d, Dict("files" => String[]), "user-synths")
                # The orphan must have registered, so _is_user_synth
                # accepts it — otherwise pattern fires route to /dirt/play
                # and SuperDirt rejects with "instrument not found".
                @test Ressac.synth_info(:auto) !== nothing
                @test Ressac._is_user_synth(:auto)
            end
        end
        empty!(Ressac._SYNTH_REGISTRY)
    end

    @testset "_is_user_synth accepts user-synths AND user-dsl plugins" begin
        empty!(Ressac._SYNTH_REGISTRY)
        try
            Ressac.register_synth!(Ressac.SynthEntry(:from_scd, "user-synths", Dict{String,Any}()))
            Ressac.register_synth!(Ressac.SynthEntry(:from_jl,  "user-dsl",    Dict{String,Any}()))
            Ressac.register_synth!(Ressac.SynthEntry(:from_other, "superdirt-synths", Dict{String,Any}()))
            @test Ressac._is_user_synth(:from_scd)
            @test Ressac._is_user_synth(:from_jl)
            @test !Ressac._is_user_synth(:from_other)
            @test !Ressac._is_user_synth(:not_registered)
        finally
            empty!(Ressac._SYNTH_REGISTRY)
        end
    end
end
