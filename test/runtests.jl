using Test
using Ressac

@testset "Ressac.jl" begin
    @testset "M0 — bootstrap" begin
        @test isdefined(@__MODULE__, :Ressac)
    end

    include("test_core.jl")
    include("test_combinators.jl")
    include("test_algebra.jl")
    include("test_mininotation.jl")
    include("test_osc.jl")
    include("test_scheduler.jl")
    include("test_tui.jl")
    include("test_live_api.jl")
    include("test_plugins.jl")
    include("test_plugin_handlers.jl")
    include("test_controls.jl")
    include("test_tui_hints.jl")
    include("test_tap_detection.jl")
    include("test_orbit_routing.jl")
    include("test_modal_helpers.jl")
    include("test_synth_alias.jl")
end
