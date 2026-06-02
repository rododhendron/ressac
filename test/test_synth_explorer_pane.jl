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
