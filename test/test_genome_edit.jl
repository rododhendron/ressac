include(joinpath(@__DIR__, "helpers.jl"))
using Test
using Ressac

# Les deux gestes sur le graphe qui servent hors de tout studio : retirer un
# nœud en laissant passer son signal (l'élagage), greffer un modulateur (la
# mutation).
@testset "genome_edit — retirer un nœud, greffer un modulateur" begin
    function _chain3()
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        r = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                             Ressac.ConstArg(800.0), Ressac.ConstArg(0.3)])
        v = Ressac.add_node!(g, :FreeVerb, :ar, Ressac.Arg[Ressac.NodeRef(r),
                             Ressac.ConstArg(0.3), Ressac.ConstArg(0.5), Ressac.ConstArg(0.5)])
        g.output_id = v
        return g, s, r, v
    end

    @testset "delete_node! bypasses the middle node's signal" begin
        g, s, r, v = _chain3()
        n0 = length(g.nodes)
        rf = Ressac.delete_node!(g, r)                 # supprime RLPF
        @test rf !== nothing
        @test length(g.nodes) == n0 - 1
        @test !haskey(g.nodes, r)
        # FreeVerb voit désormais Saw en entrée (bypass)
        @test any(a -> a isa Ressac.NodeRef && a.id == s, g.nodes[v].args)
        @test occursin(".ar", Ressac.render_synthdef(g, :x))
    end

    @testset "delete_node! refuses a pure source (no bypass path)" begin
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        f = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                             Ressac.ConstArg(800.0), Ressac.ConstArg(0.3)])
        g.output_id = f
        @test Ressac.delete_node!(g, s) === nothing    # Saw n'a pas d'entrée audio
        @test haskey(g.nodes, s)
    end

    @testset "graft_mod! replaces a ConstArg slot with an LFO" begin
        g, s, r, v = _chain3()
        @test g.nodes[r].args[2] isa Ressac.ConstArg       # cutoff = ConstArg
        mid = Ressac.graft_mod!(g, r; arg_index = 2)        # greffe un LFO sur cutoff
        if isempty(Ressac.catalog_by_role(:mod))
            @test mid === nothing                           # pas de modulateur au catalogue
        else
            @test mid !== nothing
            @test g.nodes[r].args[2] isa Ressac.NodeRef     # devenu une modulation
            @test g.nodes[r].args[2].id == mid
            @test Ressac.ugen_spec(g.nodes[mid].ugen).role === :mod
            @test occursin(".ar", Ressac.render_synthdef(g, :x))
        end
    end

    @testset "graft_mod! on a non-ConstArg / bad index returns nothing" begin
        g, s, r, v = _chain3()
        @test Ressac.graft_mod!(g, r; arg_index = 1) === nothing   # arg 1 = NodeRef, pas ConstArg
        @test Ressac.graft_mod!(g, r; arg_index = 0) === nothing   # index invalide
    end
end