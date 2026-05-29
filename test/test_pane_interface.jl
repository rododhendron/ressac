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

# Reload the core pane kind files to restore registrations that the
# testsets above wiped via `empty!(Ressac._PANE_KINDS)`. Idempotent —
# include only the files that exist (the 4 core kinds land in 4
# separate Tasks 4-7; earlier tasks have fewer files on disk).
function _reload_core_pane_kinds()
    for f in ("pane_editor.jl", "pane_log.jl", "pane_doc.jl", "pane_scope.jl")
        path = joinpath(@__DIR__, "..", "src", f)
        isfile(path) && Base.include(Ressac, path)
    end
end

@testset "pane_editor — :editor kind" begin
    _reload_core_pane_kinds()

    @testset "registered + constructible from args" begin
        ep = Ressac._pane_new(:editor, Dict{String,Any}(
            "buffer_role" => "patterns",
            "name"        => "main",
        ))
        @test ep isa Ressac.EditorPane
        @test length(ep.tabs) == 1
        @test ep.tabs[1].role === :patterns
        @test ep.tabs[1].name == "main"
        @test Ressac.title(ep) == "main"
    end

    @testset "default_mode === :tile" begin
        ep = Ressac._pane_new(:editor, Dict{String,Any}())
        @test Ressac.default_mode(ep) === :tile
    end

    @testset "buffer_role defaults to :patterns" begin
        ep = Ressac._pane_new(:editor, Dict{String,Any}())
        @test ep.tabs[1].role === :patterns
    end

    @testset "serialize captures tab list + current_tab + roles" begin
        ep = Ressac._pane_new(:editor, Dict{String,Any}(
            "buffer_role" => "synth", "name" => "wob1",
        ))
        s = Ressac.serialize(ep)
        @test haskey(s, "tabs")
        @test length(s["tabs"]) == 1
        @test s["tabs"][1]["role"] == "synth"
        @test s["tabs"][1]["name"] == "wob1"
        @test s["current_tab"] == 1
    end
end

@testset "pane_log — :log kind" begin
    _reload_core_pane_kinds()

    @testset "registered + constructible" begin
        lp = Ressac._pane_new(:log, Dict{String,Any}())
        @test lp isa Ressac.LogPane
        @test Ressac.title(lp) == "log"
        @test Ressac.default_mode(lp) === :tile
    end

    @testset "serialize returns empty (global log is shared state)" begin
        lp = Ressac._pane_new(:log, Dict{String,Any}())
        @test Ressac.serialize(lp) == Dict{String,Any}()
    end
end
