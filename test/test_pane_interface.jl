using Test
using Ressac

# Minimal kind used to exercise the contract from outside Main.
struct _NullPane <: Ressac.PaneImpl end
Ressac.render!(::_NullPane, ::Any, ::Any) = nothing
Ressac.handle_key!(::_NullPane, ::Any) = false
Ressac.title(::_NullPane) = "null"

@testset "pane_interface" begin
    @testset "register_pane_kind! + _pane_new round-trip" begin
        empty!(Ressac._PANE_KINDS)
        Ressac.register_pane_kind!(:null, args -> _NullPane())
        p = Ressac._pane_new(:null, Dict{String,Any}())
        @test p isa _NullPane
        @test Ressac.title(p) == "null"
    end

    @testset "register_pane_kind! shadow warning on conflict" begin
        empty!(Ressac._PANE_KINDS)
        Ressac.register_pane_kind!(:dup, args -> _NullPane())
        @test_logs (:warn, r"shadowed") begin
            Ressac.register_pane_kind!(:dup, args -> _NullPane())
        end
    end

    @testset "_pane_new on unregistered kind throws ArgumentError" begin
        empty!(Ressac._PANE_KINDS)
        @test_throws ArgumentError Ressac._pane_new(:ghost, Dict{String,Any}())
    end

    @testset "defaults — default_mode is :tile" begin
        empty!(Ressac._PANE_KINDS)
        Ressac.register_pane_kind!(:null, args -> _NullPane())
        p = Ressac._pane_new(:null, Dict{String,Any}())
        @test Ressac.default_mode(p) === :tile
        @test Ressac.serialize(p) == Dict{String,Any}()
        @test Ressac.can_split(p) === true
        @test Ressac.preferred_size(p) === nothing
        @test Ressac.sidebar(p) == String[]
        @test Ressac.handle_mouse!(p, nothing) === false
        @test Ressac.on_focus!(p) === nothing
        @test Ressac.on_blur!(p) === nothing
        @test Ressac.on_close!(p) === nothing
    end
end
