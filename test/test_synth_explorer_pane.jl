using Test
using Ressac
import Tachikoma

# test_pane_interface.jl vide _PANE_KINDS et ne ré-enregistre que les
# kinds core ; on ré-inclut le fichier du pane pour re-déclarer :explorer.
Base.include(Ressac, joinpath(@__DIR__, "..", "src", "pane_synth_explorer.jl"))

@testset "synth explorer pane — render" begin
    @testset "ctor builds a 9-candidate population from a seed" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "drone_grave", "rng" => 42))
        @test p isa Ressac.SynthExplorerPane
        @test length(p.pop.candidates) == 9
        @test p.focus == 1
    end

    @testset "title mentions the explorer + generation" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 1))
        @test occursin("explorer", lowercase(Ressac.title(p)))
    end

    @testset "render! draws the header + a structural summary" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "drone_grave", "rng" => 5))
        tb = Tachikoma.TestBackend(80, 24)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 80, 24), tb.buf)
        top = Tachikoma.row_text(tb, 1)
        @test occursin("EXPLORER", uppercase(top))
        whole = join((Tachikoma.row_text(tb, r) for r in 1:24))
        @test occursin("gén", whole) || occursin("gen", whole)
    end

    @testset "genome_summary names dominant ugens" begin
        g = Ressac.archetype(:drone_grave)
        s = Ressac._genome_summary(g)
        @test occursin("Saw", s) || occursin("RLPF", s)
    end

    @testset "serialize captures seed + generation" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "pluck", "rng" => 9))
        d = Ressac.serialize(p)
        @test d["kind_seed"] == "pluck"
        @test haskey(d, "generation")
    end
end

@testset "synth explorer pane — interactions" begin
    mk() = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 7))

    @testset "l / h move focus horizontally" begin
        p = mk()
        @test Ressac.handle_key!(p, Tachikoma.KeyEvent('l')) == true
        @test p.focus == 2
        Ressac.handle_key!(p, Tachikoma.KeyEvent('h'))
        @test p.focus == 1
    end

    @testset "j / k move focus by a row (3 cols)" begin
        p = mk()
        Ressac.handle_key!(p, Tachikoma.KeyEvent('j'))
        @test p.focus == 4
        Ressac.handle_key!(p, Tachikoma.KeyEvent('k'))
        @test p.focus == 1
    end

    @testset "digit keys jump focus" begin
        p = mk()
        Ressac.handle_key!(p, Tachikoma.KeyEvent('5'))
        @test p.focus == 5
    end

    @testset "f favors, d devalues the focused candidate" begin
        p = mk()
        Ressac.handle_key!(p, Tachikoma.KeyEvent('f'))
        @test p.pop.candidates[1].weight > 0
        Ressac.handle_key!(p, Tachikoma.KeyEvent('5'))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('d'))
        @test p.pop.candidates[5].weight < 0
    end

    @testset "n advances the generation" begin
        p = mk()
        Ressac.handle_key!(p, Tachikoma.KeyEvent('f'))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('n'))
        @test p.pop.generation == 1
    end

    @testset "[ / ] adjust the divergence radius" begin
        p = mk()
        before = p.radius
        Ressac.handle_key!(p, Tachikoma.KeyEvent(']'))
        @test p.radius > before
        Ressac.handle_key!(p, Tachikoma.KeyEvent('['))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('['))
        @test p.radius < before
    end

    @testset "Space plays via the live scheduler (mock)" begin
        if !isdefined(Main, :MockOSCClient)
            mutable struct MockOSCClient; sent::Vector{Vector{UInt8}}; end
            MockOSCClient() = MockOSCClient(Vector{UInt8}[])
            Ressac.send_osc(c::MockOSCClient, b::Vector{UInt8}) = push!(c.sent, b)
        end
        mock = MockOSCClient()
        sched = Ressac.Scheduler(mock; cps = 0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            p = mk()
            Ressac.handle_key!(p, Tachikoma.KeyEvent(' '))
            @test length(mock.sent) >= 1
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "unhandled key returns false" begin
        p = mk()
        @test Ressac.handle_key!(p, Tachikoma.KeyEvent('Z')) == false
    end
end

@testset "synth explorer pane — keyboard + drone" begin
    # MockOSCClient est défini au top-level par test_synth_audition.jl
    # (inclus avant ce fichier dans runtests.jl).
    function _with_mock(f)
        mock = MockOSCClient()
        sched = Ressac.Scheduler(mock; cps = 0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            f(mock)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "m toggles keyboard sub-mode, Esc leaves it" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 3))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('m'))
        @test p.keyboard_mode == true
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:escape))
        @test p.keyboard_mode == false
    end

    @testset "in keyboard mode a note key plays (mock)" begin
        _with_mock() do mock
            p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 3))
            Ressac.handle_key!(p, Tachikoma.KeyEvent('m'))
            Ressac.handle_key!(p, Tachikoma.KeyEvent('z'))
            @test length(mock.sent) >= 1
            @test p.keyboard_mode == true
        end
    end

    @testset "t toggles drone hold (mock)" begin
        _with_mock() do mock
            p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 3))
            Ressac.handle_key!(p, Tachikoma.KeyEvent('t'))
            @test p.audition.held_active == true
            Ressac.handle_key!(p, Tachikoma.KeyEvent('t'))
            @test p.audition.held_active == false
        end
    end

    @testset "on_close! stops the drone (mock)" begin
        _with_mock() do mock
            p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 3))
            Ressac.handle_key!(p, Tachikoma.KeyEvent('t'))
            Ressac.on_close!(p)
            @test p.audition.held_active == false
        end
    end
end

@testset "synth explorer pane — details overlay" begin
    @testset "genome_depth measures the longest signal path" begin
        g = Ressac.archetype(:drone_grave)   # Saw -> RLPF
        @test Ressac._genome_depth(g) >= 2
    end

    @testset "i opens the overlay, Esc closes it" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 8))
        @test p.inspect == false
        Ressac.handle_key!(p, Tachikoma.KeyEvent('i'))
        @test p.inspect == true
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:escape))
        @test p.inspect == false
    end

    @testset "overlay renders the DSL + stats of the focused candidate" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "drone_grave", "rng" => 8))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('i'))
        tb = Tachikoma.TestBackend(80, 24)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 80, 24), tb.buf)
        whole = join((Tachikoma.row_text(tb, r) for r in 1:24))
        @test occursin("@synth", whole)
        @test occursin("nœuds", whole) || occursin("nodes", whole)
    end
end

@testset "synth explorer pane — commit save" begin
    @testset "s enters seed-naming mode, typing builds the name" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 2))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('s'))
        @test p.naming === :seed
        Ressac.handle_key!(p, Tachikoma.KeyEvent('a'))
        Ressac.handle_key!(p, Tachikoma.KeyEvent('b'))
        @test p.name_buf == "ab"
        Ressac.handle_key!(p, Tachikoma.KeyEvent(:escape))
        @test p.naming === :none
        @test p.name_buf == ""
    end

    @testset "Enter in seed mode writes a JSON seed" begin
        mktempdir() do dir
            p = Ressac._pane_new(:explorer, Dict{String,Any}(
                "seed" => "pluck", "rng" => 2))
            p.seed_dir_override = dir
            Ressac.handle_key!(p, Tachikoma.KeyEvent('s'))
            for c in "myseed"
                Ressac.handle_key!(p, Tachikoma.KeyEvent(c))
            end
            Ressac.handle_key!(p, Tachikoma.KeyEvent(:enter))
            @test isfile(joinpath(dir, "myseed.json"))
            @test p.naming === :none
        end
    end

    @testset "Enter in synth mode writes a .jl DSL file" begin
        mktempdir() do dir
            p = Ressac._pane_new(:explorer, Dict{String,Any}("rng" => 2))
            p.user_synth_dir_override = dir
            Ressac.handle_key!(p, Tachikoma.KeyEvent('w'))
            @test p.naming === :synth
            for c in "wobz"
                Ressac.handle_key!(p, Tachikoma.KeyEvent(c))
            end
            Ressac.handle_key!(p, Tachikoma.KeyEvent(:enter))
            path = joinpath(dir, "wobz.jl")
            @test isfile(path)
            @test occursin("@synth", read(path, String))
        end
    end
end

@testset "synth explorer pane — session persistence" begin
    @testset ":explorer is a registered pane kind" begin
        @test haskey(Ressac._PANE_KINDS, :explorer)
    end

    @testset "serialize captures the full population" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "pluck", "rng" => 3))
        Ressac.favor!(p.pop, 2)
        d = Ressac.serialize(p)
        @test haskey(d, "population")
        @test length(d["population"]) == 9
    end

    @testset "round-trip restores candidates + weights + generation" begin
        p = Ressac._pane_new(:explorer, Dict{String,Any}(
            "seed" => "pluck", "rng" => 3))
        Ressac.favor!(p.pop, 2)
        Ressac.handle_key!(p, Tachikoma.KeyEvent('f'))
        gen_before = p.pop.generation
        d = Ressac.serialize(p)
        p2 = Ressac._pane_new(:explorer, d)
        @test length(p2.pop.candidates) == 9
        @test p2.pop.generation == gen_before
        @test p2.pop.candidates[2].weight > 0
        s1 = Ressac.render_synthdef(p.pop.candidates[5].genome, :x)
        s2 = Ressac.render_synthdef(p2.pop.candidates[5].genome, :x)
        @test s1 == s2
    end
end
