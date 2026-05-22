using Test
using Ressac

@testset "controls" begin
    @testset "ControlMap alias resolves to Dict{Symbol,Any}" begin
        cm = Ressac.ControlMap(:s => :bd, :gain => 0.8)
        @test cm isa Dict{Symbol,Any}
        @test cm[:s] === :bd
        @test cm[:gain] === 0.8
    end

    @testset "_symbol_to_control_map plain symbol → :s only" begin
        cm = Ressac._symbol_to_control_map(:bd)
        @test cm == Dict{Symbol,Any}(:s => :bd)
    end

    @testset "_symbol_to_control_map bd:1 → :s + :n" begin
        cm = Ressac._symbol_to_control_map(Symbol("bd:1"))
        @test cm[:s] === :bd
        @test cm[:n] === 1
    end

    @testset "_symbol_to_control_map bd:12 (multi-digit)" begin
        cm = Ressac._symbol_to_control_map(Symbol("snares:12"))
        @test cm[:s] === :snares
        @test cm[:n] === 12
    end
end
