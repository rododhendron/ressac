# L'élagage : indices statiques, impact mesuré (analyse simulée), prune!,
# et le studio sculpt (P, ✂, :prune).
using Test
using Ressac
using Tachikoma

# Saw → RLPF → Tanh → Fold2(1) → Fold2(1) (le second est redondant) ; un
# Saw à 0 Hz mixé dedans ; un MulAdd identité ; un nœud hors chaîne.
function _prune_genome()
    g = Ressac.Genome()
    A = Ressac.Arg; N = Ressac.NodeRef; C = Ressac.ConstArg
    s  = Ressac.add_node!(g, :Saw, :ar, A[Ressac.ControlRef(:freq)])
    f  = Ressac.add_node!(g, :RLPF, :ar, A[N(s), C(800.0), C(0.3)])
    t  = Ressac.add_node!(g, :Tanh, :ar, A[N(f)])
    f1 = Ressac.add_node!(g, :Fold2, :ar, A[N(t), C(1.0)])
    f2 = Ressac.add_node!(g, :Fold2, :ar, A[N(f1), C(1.0)])
    z  = Ressac.add_node!(g, :Saw, :ar, A[C(0.0)])
    mx = Ressac.add_node!(g, :Mix, :ar, A[N(f2), N(z)])
    id = Ressac.add_node!(g, :MulAdd, :ar, A[N(mx), C(1.0), C(0.0)])
    dead = Ressac.add_node!(g, :SinOsc, :ar, A[C(440.0), C(0.0)])
    g.output_id = id
    return g, (s = s, f = f, t = t, f1 = f1, f2 = f2, z = z, mx = mx, id = id, dead = dead)
end

@testset "élagage — indices statiques" begin
    g, n = _prune_genome()
    hints = Dict(h.id => h.reason for h in Ressac.static_prune_hints(g))
    @test occursin("hors de la chaîne", hints[n.dead])
    @test occursin("sort de Fold2", hints[n.f2]) || occursin("redondant", hints[n.f2])
    @test occursin("déjà dans ±1", hints[n.f1])            # Fold2(1) après un Tanh
    @test occursin("fréquence 0", hints[n.z])
    @test !haskey(hints, n.s) && !haskey(hints, n.f) && !haskey(hints, n.t)
    @test !haskey(hints, n.id)                                # la sortie n'est jamais proposée
    # un graphe sain : rien
    g2 = Ressac.Genome(); a = Ressac.add_node!(g2, :Saw, :ar, Ressac.Arg[Ressac.ControlRef(:freq)])
    b = Ressac.add_node!(g2, :RLPF, :ar, Ressac.Arg[Ressac.NodeRef(a), Ressac.ConstArg(800.0), Ressac.ConstArg(0.3)]); g2.output_id = b
    @test isempty(Ressac.static_prune_hints(g2))
end

# Une analyse simulée : le « son » est le multiset d'UGens de la chaîne,
# projeté sur six descripteurs — retirer un Fold2 redondant ne change rien
# (deux Fold2 → un Fold2 : on compte les Fold2 au plus 1), retirer le
# filtre change tout.
function _fake_analyze(gs)
    map(gs) do g
        names = [g.nodes[i].ugen for i in Ressac._topo_order(g)]
        Float64[count(==(:RLPF), names), min(1, count(==(:Fold2), names)), count(==(:Tanh), names),
                count(==(:Saw), names) / 2, 0.0, 0.0]
    end
end

@testset "élagage — impact mesuré et prune!" begin
    g, n = _prune_genome()
    imps = Ressac.measure_impacts(g; analyze = _fake_analyze)
    by = Dict(r.id => r.impact for r in imps)
    @test by[n.f2] == 0.0 && by[n.f1] == 0.0                  # les Fold2 : rien
    @test by[n.f] > 0.3 && by[n.t] > 0.3                      # le filtre, la saturation : beaucoup
    @test !haskey(by, n.id)                                   # la sortie n'est pas mesurée
    @test !haskey(by, n.s) || by[n.s] > 0                     # une source pure ne se contourne pas
    @test issorted([r.impact for r in imps])
    removed = Ressac.prune!(g, imps; threshold = 0.02)
    @test n.f2 in removed && n.f1 in removed && !(n.f in removed) && !(n.t in removed)
    @test !haskey(g.nodes, n.f2) && haskey(g.nodes, n.t)
    @test Ressac.render_synthdef(g, :x) isa String            # le graphe reste valide
    @test_throws ErrorException Ressac.measure_impacts(g; analyze = gs -> Vector{Float64}[])
end

@testset "élagage — le studio sculpt : P, ✂, :prune" begin
    if !isdefined(Main, :MockOSCClient)
        @eval Main begin
            mutable struct MockOSCClient; sent::Vector{Vector{UInt8}}; end
            MockOSCClient() = MockOSCClient(Vector{UInt8}[])
            Ressac.send_osc(c::MockOSCClient, bytes::Vector{UInt8}) = push!(c.sent, bytes)
        end
    end
    old_an = Ressac._PRUNE_ANALYZE[]; old_render = Ressac._WAVE_RENDER[]; old_sync = Ressac._WAVE_SYNC[]
    Ressac._PRUNE_ANALYZE[] = _fake_analyze
    Ressac._WAVE_RENDER[] = g -> (Float32[0.0f0, 0.1f0, 0.0f0], 44100)
    Ressac._WAVE_SYNC[] = true
    try
        g, n = _prune_genome()
        p = Ressac._pane_new(:waveform, Dict{String,Any}("genome" => Ressac.serialize_genome(g), "label" => "t", "sculpt" => true))
        @test p isa Ressac.WaveformPane && p.sculpt
        @test any(l -> occursin("ÉLAGAGE", l), p.explain_lines)
        @test any(l -> occursin("fréquence 0", l), p.explain_lines)      # indices dès l'ouverture
        @test haskey(p.hints, n.dead)
        tb = Tachikoma.TestBackend(100, 30)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 100, 30), tb.buf)
        scr = join((Tachikoma.row_text(tb, y) for y in 1:30), "\n")
        @test occursin("✂", scr)
        # P mesure (synchrone en test)
        @test Ressac.handle_key!(p, Tachikoma.KeyEvent('P')) == true
        @test !p.measuring && !isempty(p.impacts) && p.impacts[n.f2] == 0.0
        @test any(l -> occursin("impact", l), p.explain_lines)
        # :prune retire les ✂ mesurés, pas le filtre
        nb = Ressac._sculpt_prune!(p)
        @test nb >= 2 && !haskey(p.genome.nodes, n.f2) && haskey(p.genome.nodes, n.f)
        @test isempty(p.impacts)                                         # périmés après la coupe
        # un édit structurel vide aussi les impacts
        Ressac.handle_key!(p, Tachikoma.KeyEvent('P')); @test !isempty(p.impacts)
        Ressac.handle_key!(p, Tachikoma.KeyEvent('n')); @test isempty(p.impacts)
        # sans mesure, :prune ne fait rien ; avec une analyse qui échoue, le message le dit
        @test Ressac._sculpt_prune!(p) == 0
        Ressac._PRUNE_ANALYZE[] = gs -> error("nrt: sclang introuvable")
        Ressac.handle_key!(p, Tachikoma.KeyEvent('P'))
        @test !p.measuring && isempty(p.impacts) && any(l -> occursin("indisponible", l), p.explain_lines)
    finally
        Ressac._PRUNE_ANALYZE[] = old_an; Ressac._WAVE_RENDER[] = old_render; Ressac._WAVE_SYNC[] = old_sync
    end
end
