using Test
using Ressac

# Saw(freq ctrl) → RLPF(in, cutoff=800, rq=0.3). The two RLPF ConstArgs
# are knobs; Saw's freq is a ControlRef (not a ConstArg) → not a node knob.
function _sculpt_genome()
    g = Ressac.Genome()
    s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
    f = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                         Ressac.ConstArg(800.0), Ressac.ConstArg(0.3)])
    g.output_id = f
    return g, s, f
end

@testset "wave_sculpt — knob core" begin
    @testset "enumerate: globals first, then node knobs in spine order" begin
        g, s, f = _sculpt_genome()
        ks = Ressac.enumerate_knobs(g)
        @test [k.name for k in ks[1:4]] == [:freq, :sustain, :gain, :release]
        @test all(k.kind === :control for k in ks[1:4])
        node_knobs = [k for k in ks if k.kind === :node]
        @test length(node_knobs) == 2
        @test all(k.node_id == f for k in node_knobs)
        @test Set(k.arg_index for k in node_knobs) == Set([2, 3])
    end

    @testset "log inference: freq-like slots & :freq control are log" begin
        g, _, _ = _sculpt_genome()
        ks = Ressac.enumerate_knobs(g)
        freqctl = ks[findfirst(k -> k.name === :freq && k.kind === :control, ks)]
        @test freqctl.logscale
        gain = ks[findfirst(k -> k.name === :gain, ks)]
        @test !gain.logscale
        cutoff = ks[findfirst(k -> k.kind === :node && k.arg_index == 2, ks)]
        @test cutoff.logscale
    end

    @testset "value read + write round-trips" begin
        g, _, f = _sculpt_genome()
        ks = Ressac.enumerate_knobs(g)
        cutoff = ks[findfirst(k -> k.kind === :node && k.arg_index == 2, ks)]
        @test Ressac.knob_value(g, cutoff) == 800.0
        Ressac.set_knob!(g, cutoff, 1200.0)
        @test Ressac.knob_value(g, cutoff) == 1200.0
        @test g.nodes[f].args[2] isa Ressac.ConstArg
        freqctl = ks[findfirst(k -> k.name === :freq && k.kind === :control, ks)]
        Ressac.set_knob!(g, freqctl, 110.0)
        @test Ressac.control(g, :freq) == 110.0
    end

    @testset "tug: log moves multiplicatively, overflow allowed (no hard cap)" begin
        g, _, _ = _sculpt_genome()
        ks = Ressac.enumerate_knobs(g)
        cutoff = ks[findfirst(k -> k.kind === :node && k.arg_index == 2, ks)]
        up = Ressac.knob_tug(cutoff, 800.0, 4)
        @test up > 800.0
        down = Ressac.knob_tug(cutoff, 800.0, -4)
        @test down < 800.0
        # overflow : on peut dépasser la plage nominale du catalogue
        @test Ressac.knob_tug(cutoff, cutoff.hi, 10) > cutoff.hi
        # mais reste borné par le bon sens absolu
        @test Ressac.knob_tug(cutoff, 1.0e9, 1) <= 2.0e4
    end

    @testset "knob_set_value: exact value, beyond nominal range, sane bounds" begin
        g, _, _ = _sculpt_genome()
        ks = Ressac.enumerate_knobs(g)
        cutoff = ks[findfirst(k -> k.kind === :node && k.arg_index == 2, ks)]
        @test Ressac.knob_set_value(cutoff, 2500.0) == 2500.0   # exact, > nominal hi
        @test Ressac.knob_set_value(cutoff, 1.0e9) <= 2.0e4     # borné
    end

    @testset "linear tug for non-log knob" begin
        g, _, _ = _sculpt_genome()
        ks = Ressac.enumerate_knobs(g)
        rq = ks[findfirst(k -> k.kind === :node && k.arg_index == 3, ks)]
        @test !rq.logscale
        @test Ressac.knob_tug(rq, 0.3, 2) > 0.3
        @test Ressac.knob_tug(rq, 0.3, -2) < 0.3
    end
end

@testset "wave_sculpt — graph proximity" begin
    function _chain()
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        r = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                             Ressac.ConstArg(800.0), Ressac.ConstArg(0.3)])
        v = Ressac.add_node!(g, :FreeVerb, :ar, Ressac.Arg[Ressac.NodeRef(r),
                             Ressac.ConstArg(0.3), Ressac.ConstArg(0.5), Ressac.ConstArg(0.5)])
        g.output_id = v
        return g, s, r, v
    end

    @testset "adjacency is undirected and covers edges" begin
        g, s, r, v = _chain()
        adj = Ressac.build_adjacency(g)
        @test r in adj[s] && s in adj[r]
        @test v in adj[r] && r in adj[v]
    end

    @testset "hop distance via BFS" begin
        g, s, r, v = _chain()
        adj = Ressac.build_adjacency(g)
        @test Ressac.hop_distance(adj, r, r) == 0
        @test Ressac.hop_distance(adj, s, r) == 1
        @test Ressac.hop_distance(adj, s, v) == 2
    end

    @testset "knob distance: same node = 0, neighbours small, normalized [0,1]" begin
        g, s, r, v = _chain()
        ks = Ressac.enumerate_knobs(g)
        D = Ressac.knob_graph_distances(g, ks)
        n = length(ks)
        @test size(D) == (n, n)
        @test all(0.0 <= D[i, j] <= 1.0 for i in 1:n, j in 1:n)
        @test all(D[i, i] == 0.0 for i in 1:n)
        rlpf = findall(k -> k.kind === :node && k.node_id == r, ks)
        @test length(rlpf) == 2
        @test D[rlpf[1], rlpf[2]] == 0.0
        verb = findfirst(k -> k.kind === :node && k.node_id == v, ks)
        @test D[rlpf[1], rlpf[2]] < D[rlpf[1], verb]
    end
end

@testset "wave_sculpt — descriptors, signatures, quartiers" begin
    @testset "descriptors_from_samples: sine is dark/tonal, noise is bright/noisy" begin
        sr = 44100
        sine = Float32[sin(2π * 110 * i / sr) for i in 0:(sr ÷ 2)]
        rng = Ressac.Random.MersenneTwister(1)
        noise = Float32[2f0 * rand(rng, Float32) - 1f0 for _ in 0:(sr ÷ 2)]
        ds = Ressac.descriptors_from_samples(sine, sr)
        dn = Ressac.descriptors_from_samples(noise, sr)
        @test length(ds) == 5
        @test all(0.0 .<= ds .<= 1.0)
        @test dn[1] > ds[1]
        @test dn[3] > ds[3]
    end

    @testset "empty samples → zero vector, no crash" begin
        @test Ressac.descriptors_from_samples(Float32[], 44100) == zeros(5)
    end

    @testset "signatures accumulate a direction; cosine close for parallel" begin
        sigs = Ressac.KnobSignatures()
        Ressac.update_signature!(sigs, 1, [1.0, 0.0, 0.0, 0.0, 0.0])
        Ressac.update_signature!(sigs, 2, [2.0, 0.0, 0.0, 0.0, 0.0])
        Ressac.update_signature!(sigs, 3, [0.0, 0.0, 1.0, 0.0, 0.0])
        @test Ressac.n_signatures(sigs) == 3
        @test Ressac._ac_dist(sigs, 1, 2) < Ressac._ac_dist(sigs, 1, 3)
    end

    @testset "soft_quartiers: tight clusters, boundary knobs lose strength" begin
        D = [0.0 0.1 0.8 0.9 0.5;
             0.1 0.0 0.7 0.8 0.5;
             0.8 0.7 0.0 0.1 0.6;
             0.9 0.8 0.1 0.0 0.6;
             0.5 0.5 0.6 0.6 0.0]
        labels, strength = Ressac.soft_quartiers(D; threshold = 0.34)
        @test labels[1] == labels[2]
        @test labels[3] == labels[4]
        @test labels[1] != labels[3]
        @test length(strength) == 5
        @test all(0.0 .<= strength .<= 1.0)
        @test strength[5] <= strength[1]
    end

    @testset "mixed_distances: α=0 → pure graph; signatures pull α up" begin
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        f = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                             Ressac.ConstArg(800.0), Ressac.ConstArg(0.3)])
        g.output_id = f
        ks = Ressac.enumerate_knobs(g)
        empty_sigs = Ressac.KnobSignatures()
        Dg = Ressac.knob_graph_distances(g, ks)
        Dm = Ressac.mixed_distances(Dg, empty_sigs, ks)
        @test Dm == Dg
        # après accumulation de signatures, α>0 → la matrice se mélange (≠ graphe)
        sigs = Ressac.KnobSignatures()
        for i in 1:length(ks)
            delta = zeros(5); delta[mod1(i, 5)] = 1.0
            Ressac.update_signature!(sigs, i, delta)
        end
        Dm2 = Ressac.mixed_distances(Dg, sigs, ks)
        @test Dm2 != Dg
        @test all(0.0 <= Dm2[i, j] <= 1.0 for i in 1:length(ks), j in 1:length(ks))
    end
end

@testset "wave_sculpt — structural swap" begin
    @testset "swap_node_ugen cycles to another same-role UGen, stays valid" begin
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        f = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                             Ressac.ConstArg(800.0), Ressac.ConstArg(0.3)])
        g.output_id = f
        @test g.nodes[f].ugen === :RLPF
        nxt = Ressac.swap_node_ugen!(g, f; dir = 1)
        @test nxt !== nothing
        @test g.nodes[f].ugen !== :RLPF
        @test Ressac.ugen_spec(g.nodes[f].ugen).role === :filter   # même rôle
        @test occursin(".ar", Ressac.render_synthdef(g, :x))       # rendu-valide
    end

    @testset "swap on a missing node returns nothing" begin
        @test Ressac.swap_node_ugen!(Ressac.Genome(), 999) === nothing
    end

    @testset "structural_edit! dispatch routes to swap (returns same node)" begin
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        f = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                             Ressac.ConstArg(800.0), Ressac.ConstArg(0.3)])
        g.output_id = f
        r = Ressac.structural_edit!(g, :swap_ugen, f; dir = 1)
        @test r == f                                   # refocalise le même nœud
        @test g.nodes[f].ugen !== :RLPF
    end

    @testset "insert_node_after! wraps the node's output in a filter" begin
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
        f = Ressac.add_node!(g, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(s),
                             Ressac.ConstArg(800.0), Ressac.ConstArg(0.3)])
        g.output_id = f
        n0 = length(g.nodes)
        new_id = Ressac.structural_edit!(g, :insert_after, f)
        @test new_id !== nothing
        @test length(g.nodes) == n0 + 1                # un nœud ajouté
        @test g.output_id == new_id                    # le nouveau est la sortie
        # le nouveau nœud est un filtre qui référence l'ancien en entrée
        @test Ressac.ugen_spec(g.nodes[new_id].ugen).role === :filter
        @test any(a -> a isa Ressac.NodeRef && a.id == f, g.nodes[new_id].args)
        @test occursin(".ar", Ressac.render_synthdef(g, :x))   # rendu-valide
    end

    @testset "insert on a missing node returns nothing" begin
        @test Ressac.insert_node_after!(Ressac.Genome(), 999) === nothing
    end
end

@testset "wave_sculpt — structural bricks 3-7" begin
    # Saw → RLPF → FreeVerb (chaîne à 3 nœuds).
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

    @testset "rewire_input! redirects the audio input to another node" begin
        g, s, r, v = _chain3()
        # l'entrée de FreeVerb est RLPF ; on la recâble ailleurs (2 candidats : s, r)
        before = g.nodes[v].args[1]
        rf = Ressac.rewire_input!(g, v; dir = 1)
        @test rf == v
        @test g.nodes[v].args[1] isa Ressac.NodeRef
        @test occursin(".ar", Ressac.render_synthdef(g, :x))
    end

    @testset "toggle_rate! acts on multi-rate UGens, no-ops on single-rate" begin
        g, s, r, v = _chain3()
        # Saw = [:ar, :kr] → multi-rate : toggle agit (renvoie le node id).
        # (le rate final peut être ré-ajusté par repair! → on teste le contrat.)
        @test length(Ressac.ugen_spec(:Saw).rates) > 1
        @test Ressac.toggle_rate!(g, s; dir = 1) == s
        # RLPF = [:ar] seul → no-op.
        @test length(Ressac.ugen_spec(:RLPF).rates) == 1
        @test Ressac.toggle_rate!(g, r) === nothing
    end

    @testset "duplicate_subgraph_at! clones + mixes in parallel" begin
        g, s, r, v = _chain3()
        n0 = length(g.nodes)
        cr = Ressac.duplicate_subgraph_at!(g, r)       # duplique le sous-graphe {RLPF,Saw}
        @test cr !== nothing
        @test length(g.nodes) > n0                      # clones + Mix
        # un nœud Mix a été inséré là où RLPF était consommé (par FreeVerb)
        @test any(n -> n.ugen === :Mix, values(g.nodes))
        @test occursin(".ar", Ressac.render_synthdef(g, :x))
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
