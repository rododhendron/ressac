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
end
