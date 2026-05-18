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
end
