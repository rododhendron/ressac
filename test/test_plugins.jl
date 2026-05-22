using Test
using Ressac

@testset "plugins" begin
    @testset "section handler registry" begin
        @testset "register + get round-trip" begin
            seen = Ref{Any}(nothing)
            h = (dir, data, name) -> (seen[] = (dir, data, name); nothing)
            Ressac.register_section_handler!(:_test_section, h)
            @test Ressac.get_section_handler(:_test_section) === h
            h("/tmp", Dict("k" => "v"), "myplugin")
            @test seen[] == ("/tmp", Dict("k" => "v"), "myplugin")
            Ressac.unregister_section_handler!(:_test_section)
            @test Ressac.get_section_handler(:_test_section) === nothing
        end

        @testset "overwriting an existing handler logs a warning" begin
            h1 = (a, b, c) -> nothing
            h2 = (a, b, c) -> nothing
            Ressac.register_section_handler!(:_test_overwrite, h1)
            @test_logs (:warn, r"_test_overwrite") begin
                Ressac.register_section_handler!(:_test_overwrite, h2)
            end
            @test Ressac.get_section_handler(:_test_overwrite) === h2
            Ressac.unregister_section_handler!(:_test_overwrite)
        end

        @testset "get returns nothing for unknown section" begin
            @test Ressac.get_section_handler(:_does_not_exist) === nothing
        end
    end

    @testset "manifest parsing" begin
        fixtures = joinpath(@__DIR__, "fixtures", "plugins")

        @testset "valid manifest returns name/version/description + sections" begin
            m = Ressac.parse_manifest(joinpath(fixtures, "foo"))
            @test m.name == "foo"
            @test m.version == "0.1.0"
            @test m.description == "fixture plugin used in plugin loader tests"
            @test m.dir == joinpath(fixtures, "foo")
            @test haskey(m.sections, "samples")
            @test m.sections["samples"]["roots"] == ["./samples"]
        end

        @testset "name mismatch throws ArgumentError" begin
            @test_throws ArgumentError Ressac.parse_manifest(
                joinpath(fixtures, "bad-name"))
        end

        @testset "missing plugin.toml throws ArgumentError" begin
            @test_throws ArgumentError Ressac.parse_manifest(
                joinpath(fixtures, "no-manifest"))
        end
    end

    @testset "search path resolution" begin
        fixtures      = joinpath(@__DIR__, "fixtures", "plugins")
        fixtures_alt  = joinpath(@__DIR__, "fixtures", "plugins-alt")

        @testset "discovers good plugins; bad ones logged but excluded" begin
            results = @test_logs (:warn, r"bad-name") match_mode=:any begin
                Ressac.discover_plugins([fixtures])
            end
            names = [m.name for m in results]
            @test "foo" in names
            @test !("wrong-name" in names)
            @test !("no-manifest" in names)
        end

        @testset "first hit wins on a multi-path search" begin
            found = Ressac.discover_plugins([fixtures, fixtures_alt])
            foo = only(filter(m -> m.name == "foo", found))
            @test foo.version == "0.1.0"
        end

        @testset "reverse order: alt-then-primary picks alt" begin
            found = Ressac.discover_plugins([fixtures_alt, fixtures])
            foo = only(filter(m -> m.name == "foo", found))
            @test foo.version == "9.9.9"
        end

        @testset "non-existent path is silently skipped" begin
            found = Ressac.discover_plugins(["/no/such/path", fixtures])
            @test any(m -> m.name == "foo", found)
        end
    end

    @testset "topological sort" begin
        mk(name, deps=String[]) = Ressac.PluginManifest(
            name, "0.0.0", "test", "/fake/$name", Dict{String,Any}(), deps)

        @testset "no dependencies → stable order" begin
            ms = [mk("a"), mk("b"), mk("c")]
            sorted = Ressac.topo_sort(ms)
            @test [m.name for m in sorted] == ["a", "b", "c"]
        end

        @testset "respects depends_on" begin
            ms = [mk("c", ["a"]), mk("a"), mk("b", ["a"])]
            sorted = Ressac.topo_sort(ms)
            names = [m.name for m in sorted]
            @test findfirst(==("a"), names) < findfirst(==("c"), names)
            @test findfirst(==("a"), names) < findfirst(==("b"), names)
        end

        @testset "missing dep is logged and the plugin is skipped" begin
            ms = [mk("needs-ghost", ["ghost"])]
            sorted = @test_logs (:warn, r"ghost") match_mode=:any begin
                Ressac.topo_sort(ms)
            end
            @test isempty(sorted)
        end

        @testset "cycle is detected and breaks the cycle (both skipped)" begin
            ms = [mk("a", ["b"]), mk("b", ["a"])]
            sorted = @test_logs (:warn, r"cycle") match_mode=:any begin
                Ressac.topo_sort(ms)
            end
            @test isempty(sorted)
        end
    end

    @testset "load_plugin orchestrator" begin
        @testset "calls each section's handler with (dir, data, name)" begin
            calls = Tuple[]
            handler = (dir, data, name) -> push!(calls, (Symbol("samples"), dir, data, name))
            saved = Ressac.get_section_handler(:samples)
            Ressac.register_section_handler!(:samples, handler)
            try
                m = Ressac.parse_manifest(joinpath(@__DIR__, "fixtures", "plugins", "foo"))
                Ressac.load_plugin(m)
                @test length(calls) == 1
                _, dir, data, name = calls[1]
                @test name == "foo"
                @test data == Dict("roots" => ["./samples"])
                @test endswith(dir, "/foo")
            finally
                saved === nothing ? Ressac.unregister_section_handler!(:samples) :
                                    Ressac.register_section_handler!(:samples, saved)
            end
        end

        @testset "unknown section logs warning, does not throw" begin
            m = Ressac.PluginManifest(
                "ghost", "0", "x", "/fake/ghost",
                Dict("ghostly" => Dict("k" => "v")), String[])
            @test_logs (:warn, r"ghostly") match_mode=:any begin
                Ressac.load_plugin(m)
            end
        end

        @testset "handler exception is caught and logged" begin
            Ressac.register_section_handler!(:boom, (_, _, _) -> error("kaboom"))
            try
                m = Ressac.PluginManifest(
                    "boomy", "0", "x", "/fake/boomy",
                    Dict("boom" => Dict()), String[])
                @test_logs (:error, r"kaboom") match_mode=:any begin
                    Ressac.load_plugin(m)
                end
            finally
                Ressac.unregister_section_handler!(:boom)
            end
        end

        @testset "[julia] runs before other sections of the same plugin" begin
            seen_order = Symbol[]
            saved_julia   = Ressac.get_section_handler(:julia)
            saved_samples = Ressac.get_section_handler(:samples)
            Ressac.register_section_handler!(:julia,   (_, _, _) -> push!(seen_order, :julia))
            Ressac.register_section_handler!(:samples, (_, _, _) -> push!(seen_order, :samples))
            try
                m = Ressac.PluginManifest(
                    "order", "0", "x", "/fake/order",
                    Dict("samples" => Dict(), "julia" => Dict("files" => String[])),
                    String[])
                Ressac.load_plugin(m)
                @test seen_order == [:julia, :samples]
            finally
                saved_julia === nothing   ? Ressac.unregister_section_handler!(:julia)   : Ressac.register_section_handler!(:julia,   saved_julia)
                saved_samples === nothing ? Ressac.unregister_section_handler!(:samples) : Ressac.register_section_handler!(:samples, saved_samples)
            end
        end
    end

    @testset "_load_plugins entry" begin
        fixtures = joinpath(@__DIR__, "fixtures", "plugins")

        @testset "default_plugin_path includes cwd, home, env" begin
            withenv("RESSAC_PLUGIN_PATH" => "/x:/y") do
                p = Ressac.default_plugin_path()
                @test p[1] == joinpath(pwd(), "plugins")
                @test "/x" in p
                @test "/y" in p
            end
        end

        @testset "_load_plugins with custom path discovers + loads" begin
            calls = String[]
            saved = Ressac.get_section_handler(:samples)
            Ressac.register_section_handler!(:samples, (_, _, name) -> push!(calls, name))
            try
                Ressac._load_plugins([fixtures])
                @test "foo" in calls
            finally
                saved === nothing ? Ressac.unregister_section_handler!(:samples) :
                                    Ressac.register_section_handler!(:samples, saved)
            end
        end

        @testset "start_live!(plugins=false) skips loading" begin
            calls = String[]
            saved = Ressac.get_section_handler(:samples)
            Ressac.register_section_handler!(:samples, (_, _, name) -> push!(calls, name))
            try
                Ressac._LIVE_SCHEDULER[] = nothing
                sched = start_live!(plugins=false)
                try
                    @test isempty(calls)
                finally
                    stop_live!()
                end
            finally
                saved === nothing ? Ressac.unregister_section_handler!(:samples) :
                                    Ressac.register_section_handler!(:samples, saved)
            end
        end
    end

    @testset "sample registry" begin
        empty!(Ressac._SAMPLE_REGISTRY)

        @testset "register_sample! stores by name and looks up by sample_info" begin
            ent = Ressac.SampleEntry(:kicky, "funkit", "/tmp/k.wav",
                                     ["/tmp/k.wav"], Dict{String,Any}("bpm" => 120))
            Ressac.register_sample!(ent)
            got = Ressac.sample_info(:kicky)
            @test got !== nothing
            @test got.name == :kicky
            @test got.plugin == "funkit"
            @test got.variants == ["/tmp/k.wav"]
            @test got.metadata["bpm"] == 120
            empty!(Ressac._SAMPLE_REGISTRY)
        end

        @testset "sample_info returns nothing for unknown names" begin
            @test Ressac.sample_info(:does_not_exist) === nothing
        end

        @testset "shadow: second registration with same name warns and is skipped" begin
            a = Ressac.SampleEntry(:dup, "p1", "/a", ["/a"], Dict{String,Any}())
            b = Ressac.SampleEntry(:dup, "p2", "/b", ["/b"], Dict{String,Any}())
            Ressac.register_sample!(a)
            @test_logs (:warn, r"dup.*shadow") match_mode=:any begin
                Ressac.register_sample!(b)
            end
            @test Ressac.sample_info(:dup).plugin == "p1"
            empty!(Ressac._SAMPLE_REGISTRY)
        end

        @testset "list_samples returns entries sorted by plugin then name" begin
            for ent in [
                Ressac.SampleEntry(:b, "z", "/x", ["/x"], Dict{String,Any}()),
                Ressac.SampleEntry(:a, "z", "/y", ["/y"], Dict{String,Any}()),
                Ressac.SampleEntry(:c, "a", "/z", ["/z"], Dict{String,Any}()),
            ]
                Ressac.register_sample!(ent)
            end
            ordered = Ressac.list_samples()
            @test [(e.plugin, e.name) for e in ordered] ==
                  [("a", :c), ("z", :a), ("z", :b)]
            empty!(Ressac._SAMPLE_REGISTRY)
        end

        @testset "list_samples filters by regex" begin
            for ent in [
                Ressac.SampleEntry(:bd, "p", "/1", ["/1"], Dict{String,Any}()),
                Ressac.SampleEntry(:sn, "p", "/2", ["/2"], Dict{String,Any}()),
                Ressac.SampleEntry(:bd2, "p", "/3", ["/3"], Dict{String,Any}()),
            ]
                Ressac.register_sample!(ent)
            end
            kicks = Ressac.list_samples(r"^bd")
            @test sort([e.name for e in kicks]) == [:bd, :bd2]
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset "instrument registry" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)

        @testset "register_instrument! / instrument_info round-trip" begin
            ent = Ressac.InstrumentEntry(:kicklourd, "funkit",
                Pair{String,Any}["s" => "bd", "n" => 3, "gain" => 1.2],
                Dict{String,Any}("tags" => ["heavy"]))
            Ressac.register_instrument!(ent)
            got = Ressac.instrument_info(:kicklourd)
            @test got !== nothing
            @test got.name == :kicklourd
            @test got.plugin == "funkit"
            @test got.params[1] == ("s" => "bd")
            @test got.params[2] == ("n" => 3)
            @test got.metadata["tags"] == ["heavy"]
            empty!(Ressac._INSTRUMENT_REGISTRY)
        end

        @testset "instrument_info returns nothing for unknown names" begin
            @test Ressac.instrument_info(:nope) === nothing
        end

        @testset "shadow: second registration with same name warns and is skipped" begin
            a = Ressac.InstrumentEntry(:dup, "p1",
                Pair{String,Any}["s" => "bd"], Dict{String,Any}())
            b = Ressac.InstrumentEntry(:dup, "p2",
                Pair{String,Any}["s" => "sn"], Dict{String,Any}())
            Ressac.register_instrument!(a)
            @test_logs (:warn, r"dup.*shadow") match_mode=:any begin
                Ressac.register_instrument!(b)
            end
            @test Ressac.instrument_info(:dup).plugin == "p1"
            empty!(Ressac._INSTRUMENT_REGISTRY)
        end

        @testset "list_instruments sorted by plugin then name + regex filter" begin
            for ent in [
                Ressac.InstrumentEntry(:b, "z",
                    Pair{String,Any}["s" => "bd"], Dict{String,Any}()),
                Ressac.InstrumentEntry(:a, "z",
                    Pair{String,Any}["s" => "bd"], Dict{String,Any}()),
                Ressac.InstrumentEntry(:c, "a",
                    Pair{String,Any}["s" => "bd"], Dict{String,Any}()),
                Ressac.InstrumentEntry(:bd_alt, "a",
                    Pair{String,Any}["s" => "bd"], Dict{String,Any}()),
            ]
                Ressac.register_instrument!(ent)
            end
            all_inst = Ressac.list_instruments()
            @test [(e.plugin, e.name) for e in all_inst] ==
                  [("a", :bd_alt), ("a", :c), ("z", :a), ("z", :b)]
            bds = Ressac.list_instruments(r"^bd")
            @test sort([e.name for e in bds]) == [:bd_alt]
            empty!(Ressac._INSTRUMENT_REGISTRY)
        end
    end

    @testset "synth registry" begin
        empty!(Ressac._SYNTH_REGISTRY)

        @testset "register_synth! / synth_info round-trip" begin
            ent = Ressac.SynthEntry(:bassline, "funkit",
                Dict{String,Any}("tags" => ["bass"], "description" => "warm"))
            Ressac.register_synth!(ent)
            got = Ressac.synth_info(:bassline)
            @test got !== nothing
            @test got.metadata["description"] == "warm"
            empty!(Ressac._SYNTH_REGISTRY)
        end

        @testset "list_synths sorts + filters" begin
            for ent in [
                Ressac.SynthEntry(:pad, "z", Dict{String,Any}()),
                Ressac.SynthEntry(:bassline, "a", Dict{String,Any}()),
            ]
                Ressac.register_synth!(ent)
            end
            @test [e.name for e in Ressac.list_synths()] == [:bassline, :pad]
            @test [e.name for e in Ressac.list_synths(r"bass")] == [:bassline]
            empty!(Ressac._SYNTH_REGISTRY)
        end

        @testset "shadow warns" begin
            a = Ressac.SynthEntry(:dup, "p1", Dict{String,Any}())
            b = Ressac.SynthEntry(:dup, "p2", Dict{String,Any}())
            Ressac.register_synth!(a)
            @test_logs (:warn, r"dup.*shadow") match_mode=:any begin
                Ressac.register_synth!(b)
            end
            @test Ressac.synth_info(:dup).plugin == "p1"
            empty!(Ressac._SYNTH_REGISTRY)
        end
    end
end
