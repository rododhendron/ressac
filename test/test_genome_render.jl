using Test
using Ressac

@testset "genome — render" begin
    function _filtered()
        g = Ressac.Genome()
        src = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        flt = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(src),
                               Ressac.ConstArg(1200.0), Ressac.ConstArg(0.4)])
        g.output_id = flt
        return g
    end

    @testset "render_synthdef inlines the DAG + names the def" begin
        s = Ressac.render_synthdef(_filtered(), :ga_slot1)
        @test occursin("SynthDef(\\ga_slot1", s)
        @test occursin("RLPF.ar(Saw.ar(freq), 1200.0, 0.4)", s)
        @test endswith(strip(s), ".add;")
    end

    @testset "render_synthdef wraps the safety stage" begin
        s = Ressac.render_synthdef(_filtered(), :ga_slot1)
        @test occursin("Sanitize.ar", s) || occursin("CheckBadValues", s)
        @test occursin("LeakDC.ar", s)
        @test occursin("Limiter.ar", s)
        @test occursin("Out.ar", s)
    end

    @testset "render_synthdef exposes the control header" begin
        s = Ressac.render_synthdef(_filtered(), :ga_slot1)
        @test occursin("freq", s) && occursin("sustain", s) && occursin("gain", s)
    end

    @testset "special math ugens render their operator form" begin
        g = Ressac.Genome()
        src = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        t   = Ressac.add_node!(g, :Tanh, :ar, Ressac.Arg[Ressac.NodeRef(src)])
        g.output_id = t
        s = Ressac.render_synthdef(g, :x)
        @test occursin("(Saw.ar(freq)).tanh", s)
    end

    @testset "render_dsl emits a @synth string a Sig body" begin
        d = Ressac.render_dsl(_filtered(), :myseed)
        @test occursin("@synth :myseed", d)
        @test occursin("Sig(", d)
        @test occursin("RLPF.ar", d)
    end

    @testset "feedback genome renders LocalIn preamble + LocalOut" begin
        g = Ressac.Genome()
        saw = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        fb  = Ressac.add_node!(g, :FbIn, :ar, Ressac.Arg[])
        mix = Ressac.add_node!(g, :Mix, :ar,
                  Ressac.Arg[Ressac.NodeRef(saw), Ressac.NodeRef(fb)])
        g.output_id = mix
        s = Ressac.render_synthdef(g, :x)
        @test occursin("var fb = LocalIn.ar(1)", s)
        @test occursin("LocalOut.ar(sig)", s)
        d = Ressac.render_dsl(g, :x)
        @test occursin("LocalOut.ar", d)
        @test occursin(".value", d)
    end
end
