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

    @testset "_lift_to_control(Pattern{Symbol}) yields ControlPattern" begin
        p = pure(:bd)
        lifted = Ressac._lift_to_control(p)
        @test lifted isa Ressac.ControlPattern
        evs = lifted(0//1, 1//1)
        @test length(evs) == 1
        @test evs[1].value == Dict{Symbol,Any}(:s => :bd)
        @test evs[1].start == 0//1
        @test evs[1].stop  == 1//1
    end

    @testset "_lift_to_control splits :N suffix" begin
        p = pure(Symbol("snares:3"))
        lifted = Ressac._lift_to_control(p)
        evs = lifted(0//1, 1//1)
        @test evs[1].value == Dict{Symbol,Any}(:s => :snares, :n => 3)
    end

    @testset "_lift_to_control is idempotent on ControlPattern" begin
        cp = Ressac._lift_to_control(pure(:bd))
        @test Ressac._lift_to_control(cp) === cp
    end

    @testset "set(:k, scalar) on Pattern{Symbol} via auto-lift" begin
        p = pure(:bd) |> Ressac.set(:gain, 0.8)
        @test p isa Ressac.ControlPattern
        evs = p(0//1, 1//1)
        @test evs[1].value == Dict{Symbol,Any}(:s => :bd, :gain => 0.8)
    end

    @testset "set(:k, scalar) chained overwrites" begin
        p = pure(:bd) |> Ressac.set(:gain, 0.8) |> Ressac.set(:gain, 0.3)
        evs = p(0//1, 1//1)
        @test evs[1].value[:gain] == 0.3   # last write wins for set
        @test evs[1].value[:s] === :bd
    end

    @testset "set(:k, scalar) preserves other keys" begin
        p = pure(:bd) |> Ressac.set(:gain, 0.8) |> Ressac.set(:lpf, 200)
        evs = p(0//1, 1//1)
        @test evs[1].value[:gain] == 0.8
        @test evs[1].value[:lpf]  == 200
        @test evs[1].value[:s]    === :bd
    end

    @testset "set(:k, pattern) — pattern-valued override" begin
        # Gain pattern with 2 events per cycle: [0, 1/2): 0.5, [1/2, 1): 1.0
        gp = Pattern{Float64}((s, e) -> begin
            evs = Event{Float64}[]
            n_start = floor(Int, s)
            n_stop  = ceil(Int, e)
            for n in n_start:(n_stop - 1)
                base = Rational{Int64}(n)
                push!(evs, Event{Float64}(max(base, s),         min(base + 1//2, e), 0.5))
                push!(evs, Event{Float64}(max(base + 1//2, s), min(base + 1//1, e), 1.0))
            end
            filter!(ev -> ev.start < ev.stop, evs)
            evs
        end)
        p = pure(:bd) |> Ressac.set(:gain, gp)
        evs = p(0//1, 1//1)
        @test length(evs) == 2
        @test evs[1].value[:s]    === :bd
        @test evs[1].value[:gain] == 0.5
        @test evs[1].start == 0//1
        @test evs[1].stop  == 1//2
        @test evs[2].value[:gain] == 1.0
        @test evs[2].start == 1//2
        @test evs[2].stop  == 1//1
    end
end
