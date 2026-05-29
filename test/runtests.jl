using Test
using Ressac

# Load plugins so the doc + snippet registry is populated for tests
# that query `:doc <name>` or `:starter <name>`. Idempotent re-runs
# repopulate the same dicts.
empty!(Ressac._DOCS)
empty!(Ressac._DOC_ALIASES)
empty!(Ressac._SNIPPETS)
empty!(Ressac._SNIPPET_RAW)
Ressac._load_plugins([joinpath(@__DIR__, "..", "plugins")])

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
    include("test_extension_registry.jl")
    include("test_extension_registry_migration.jl")
    include("test_sc_autodiscover.jl")
    include("test_controls.jl")
    include("test_hints.jl")
    include("test_tap_detection.jl")
    include("test_orbit_routing.jl")
    include("test_modal_helpers.jl")
    include("test_synth_alias.jl")
    include("test_synth_dsl.jl")
    include("test_chaos.jl")
    include("test_reservoir.jl")
    include("test_properties.jl")
    include("test_vim_motions.jl")
end
