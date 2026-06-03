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

    @testset "render_dsl emits a clean multi-line DSL block" begin
        d = Ressac.render_dsl(_filtered(), :myseed)
        @test occursin("@synth :myseed", d)
        @test occursin("begin\n", d)            # real DSL block, not a string
        @test !occursin("Sig(\"", d)            # no giant inlined SC string
        @test occursin("ugen(:RLPF", d)
        @test occursin("ugen(:Saw, :freq)", d)
        # the emitted DSL must actually parse, expand and build a SynthDef
        src = Core.eval(Ressac.SynthDSL, Meta.parse(Ressac.SynthDSL._dsl_preprocess(d)))
        @test occursin("RLPF.ar", src)
    end

    @testset "audio-rate coercion: filter input never a bare scalar" begin
        # A filter whose audio input is a constant (e.g. after repair
        # pads a missing input) must be wrapped to audio rate, else SC
        # rejects the SynthDef ("first input is not audio rate").
        g = Ressac.Genome()
        f = Ressac.add_node!(g, :RLPF, :ar,
                Ressac.Arg[Ressac.ConstArg(0.0), Ressac.ConstArg(400.0),
                           Ressac.ConstArg(0.3)])
        g.output_id = f
        s = Ressac.render_synthdef(g, :x)
        @test occursin("RLPF.ar(DC.ar(0.0)", s)
        @test !occursin("RLPF.ar(0.0", s)        # never a raw scalar input
    end

    @testset "audio input from a kr node is wrapped via K2A" begin
        g = Ressac.Genome()
        lfo = Ressac.add_node!(g, :LFNoise1, :kr, Ressac.Arg[Ressac.ConstArg(4.0)])
        f   = Ressac.add_node!(g, :LPF, :ar,
                Ressac.Arg[Ressac.NodeRef(lfo), Ressac.ConstArg(800.0)])
        g.output_id = f
        s = Ressac.render_synthdef(g, :x)
        @test occursin("K2A.ar(LFNoise1.kr", s)
    end

    @testset "scalar math (Tanh of const) feeding a filter is wrapped" begin
        # (1.0).tanh is a SCALAR in SC even at :ar — must be DC-wrapped
        # before a filter, else SC rejects "first input is not audio rate".
        g = Ressac.Genome()
        t = Ressac.add_node!(g, :Tanh, :ar, Ressac.Arg[Ressac.ConstArg(1.0)])
        f = Ressac.add_node!(g, :HPF, :ar,
                Ressac.Arg[Ressac.NodeRef(t), Ressac.ConstArg(400.0)])
        g.output_id = f
        s = Ressac.render_synthdef(g, :x)
        @test occursin("HPF.ar(DC.ar((1.0).tanh)", s)
    end

    @testset "math carrying audio (Mix with a Saw) is NOT wrapped" begin
        g = Ressac.Genome()
        saw = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        mix = Ressac.add_node!(g, :Mix, :ar,
                Ressac.Arg[Ressac.NodeRef(saw), Ressac.ConstArg(0.0)])
        f = Ressac.add_node!(g, :HPF, :ar,
                Ressac.Arg[Ressac.NodeRef(mix), Ressac.ConstArg(400.0)])
        g.output_id = f
        s = Ressac.render_synthdef(g, :x)
        @test occursin("HPF.ar((Saw.ar(freq) + 0.0)", s)
        @test !occursin("DC.ar((Saw", s)
    end

    @testset "audio input from an ar node is left as-is" begin
        g = Ressac.Genome()
        saw = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        f   = Ressac.add_node!(g, :LPF, :ar,
                Ressac.Arg[Ressac.NodeRef(saw), Ressac.ConstArg(800.0)])
        g.output_id = f
        s = Ressac.render_synthdef(g, :x)
        @test occursin("LPF.ar(Saw.ar(freq)", s)   # no wrapper
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
        d = Ressac.render_dsl(g, :fbtest)
        @test occursin("feedback() do fb", d)   # real DSL combinator
        @test !occursin("Sig(\"", d)            # not a raw SC string
        # build it: the feedback combinator must yield LocalIn + LocalOut
        src = Core.eval(Ressac.SynthDSL, Meta.parse(Ressac.SynthDSL._dsl_preprocess(d)))
        @test occursin("LocalIn.ar(1)", src)
        @test occursin("LocalOut.ar", src)
    end
end

@testset "genome controls bake into the render + survive round-trip" begin
    g = Ressac.Genome()
    s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
    g.output_id = s
    g.controls[:freq] = 110.0
    g.controls[:sustain] = 1.5
    g.controls[:release] = 0.8
    out = Ressac.render_synthdef(g, :x)
    @test occursin("freq = 110.0", out)
    @test occursin("sustain = 1.5", out)
    @test occursin("Env.linen(0.01, sustain, 0.8)", out)
    # controls round-trip through serialization
    g2 = Ressac.deserialize_genome(Ressac.serialize_genome(g))
    @test Ressac.control(g2, :freq) == 110.0
    @test Ressac.control(g2, :release) == 0.8
end
