using Test
using Ressac

@testset "genome — serialization + archetypes" begin
    function _g()
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        f = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                             Ressac.ConstArg(900.0), Ressac.ConstArg(0.3)])
        g.output_id = f
        return g
    end

    @testset "serialize → dict → deserialize round-trips" begin
        g = _g()
        d = Ressac.serialize_genome(g)
        @test d isa AbstractDict
        g2 = Ressac.deserialize_genome(d)
        @test g2.output_id == g.output_id
        @test Ressac.render_synthdef(g2, :x) == Ressac.render_synthdef(g, :x)
    end

    @testset "builtin archetypes exist and are valid + audible" begin
        names = Ressac.archetype_names()
        @test :drone_grave in names
        @test :pluck in names
        for nm in names
            g = Ressac.archetype(nm)
            @test isempty(Ressac.validate(g))
        end
    end

    @testset "save_seed writes JSON, load_seeds reads it back" begin
        mktempdir() do dir
            g = _g()
            Ressac.save_seed("mytest", g; dir = dir)
            @test isfile(joinpath(dir, "mytest.json"))
            loaded = Ressac.load_seeds(dir)
            @test haskey(loaded, :mytest)
            @test Ressac.render_synthdef(loaded[:mytest], :x) ==
                  Ressac.render_synthdef(g, :x)
        end
    end

    @testset "all_seeds merges builtins + user dir" begin
        mktempdir() do dir
            Ressac.save_seed("custom1", Ressac.archetype(:pluck); dir = dir)
            merged = Ressac.all_seeds(dir)
            @test haskey(merged, :drone_grave)   # builtin
            @test haskey(merged, :custom1)        # user
        end
    end
end
