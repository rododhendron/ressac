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
end
