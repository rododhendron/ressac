using Test
using Ressac

@testset "Ressac.jl" begin
    @testset "M0 — bootstrap" begin
        @test isdefined(@__MODULE__, :Ressac)
    end

    include("test_core.jl")
    include("test_combinators.jl")
end
