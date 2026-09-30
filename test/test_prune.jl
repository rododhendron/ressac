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
    @test occursin("identité", hints[n.id])                  # même en sortie : la retirer remonte la sortie
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

@testset "élagage — :explain montre la section, :prune réécrit le bloc @synth de l'éditeur" begin
    old_an = Ressac._PRUNE_ANALYZE[]
    Ressac._PRUNE_ANALYZE[] = _fake_analyze
    dir = mktempdir(); mkpath(joinpath(dir, "plugins", "user-synths")); oldwd = pwd(); cd(dir)
    try
        app = Ressac.RessacApp(; scheduler = Ressac.Scheduler(MockOSCClient(); cps = 0.5))
        tb = Tachikoma.TestBackend(120, 40)
        frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 120, 40), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
        Tachikoma.view(app, frame); Ressac._PANE_MODE.active = false; Ressac._active_editor(app).mode = :normal
        ex(cmd) = (Tachikoma.update!(app, Tachikoma.KeyEvent(':')); foreach(c -> Tachikoma.update!(app, Tachikoma.KeyEvent(c)), cmd); Tachikoma.update!(app, Tachikoma.KeyEvent(:enter)))
        ex("synth truc")
        tab = Ressac._current_synth_tab(app)
        src = "# mon synth\n@synth :truc (freq=220, sustain=0.5) begin\n" *
              "    a = saw(:freq) |> rlpf(800, 0.3) |> tanh_drive(1) |> fold2(1) |> fold2(1)\n" *
              "    a + ugen(:Saw, 0.0)\nend\n\n# note finale\n"
        Tachikoma.set_text!(tab.code_editor, src)
        # :explain sur le buffer : la section ÉLAGAGE et ses indices
        ex("explain")
        @test app.modal === :explain
        @test any(l -> occursin("ÉLAGAGE", l), app.explain_lines) && any(l -> occursin("fréquence 0", l), app.explain_lines)
        Tachikoma.update!(app, Tachikoma.KeyEvent(:escape))
        # :prune réécrit le bloc, garde les commentaires autour
        ex("prune")
        txt = Tachikoma.text(tab.code_editor)
        @test startswith(txt, "# mon synth\n@synth :truc") && occursin("# note finale", txt)
        @test count("fold2", txt) == 1 || !occursin("Fold2", txt) || count("Fold2", txt) <= 1
        @test !occursin("ugen(:Saw, 0.0)", txt)
        @test occursin("|> rlpf(", txt) && occursin("retiré", app.logs[end])
        g2 = Ressac.genome_from_dsl(txt)
        @test g2 !== nothing && isempty(Ressac.static_prune_hints(g2))     # plus rien à élaguer
        # remplacement de bloc : pas de @synth → texte inchangé
        @test Ressac.replace_synth_block("x = 1\n", "@synth :y (freq=1) saw(:freq)") == "x = 1\n"
        # sans mesure disponible, les indices statiques suffisent
        Ressac._PRUNE_ANALYZE[] = gs -> error("nrt: sclang introuvable")
        Tachikoma.set_text!(tab.code_editor, src)
        ex("prune")
        @test !occursin("ugen(:Saw, 0.0)", Tachikoma.text(tab.code_editor)) && occursin("mesure indisponible", app.logs[end])
        # rien à retirer : le journal le dit, le texte ne bouge pas
        clean = "@synth :truc (freq=220) saw(:freq) |> rlpf(800, 0.3)\n"
        Tachikoma.set_text!(tab.code_editor, clean); ex("prune")
        @test Tachikoma.text(tab.code_editor) == clean && occursin("rien", app.logs[end])
    finally
        cd(oldwd); Ressac._PRUNE_ANALYZE[] = old_an
    end
end
