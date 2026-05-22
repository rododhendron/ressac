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
end
