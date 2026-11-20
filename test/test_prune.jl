include(joinpath(@__DIR__, "helpers.jl"))
# L'élagage : indices statiques, impact mesuré (analyse simulée), prune!,
# et la DOC d'un son (P, ✂) ; :prune dans le texte.
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

@testset "élagage — la DOC d'un son : indices, P, ✂" begin
    old_an = Ressac._PRUNE_ANALYZE[]; old_sync = Ressac._WAVE_SYNC[]
    Ressac._PRUNE_ANALYZE[] = _fake_analyze
    Ressac._WAVE_SYNC[] = true
    try
        g, n = _prune_genome()
        p = Ressac._pane_new(:synthdoc, Dict{String,Any}("mode" => "graph"))
        Ressac._synthdoc_set_genome!(p, g)
        @test any(l -> occursin("ÉLAGAGE", l), p.explain_lines)
        @test any(l -> occursin("fréquence 0", l), p.explain_lines)      # indices dès la lecture
        @test haskey(p.hints, n.dead)
        tb = Tachikoma.TestBackend(140, 40)
        Ressac.render!(p, Tachikoma.Rect(1, 1, 140, 40), tb.buf)
        scr = join((Tachikoma.row_text(tb, y) for y in 1:40), "\n")
        @test occursin("✂", scr)
        # P mesure (sur place en test)
        @test Ressac._synthdoc_measure_impacts!(p)
        @test !p.measuring && !isempty(p.impacts) && p.impacts[n.f2] == 0.0
        @test any(l -> occursin("impact", l), p.explain_lines)
        # un autre son : les mesures d'avant ne valent plus
        Ressac._synthdoc_set_genome!(p, first(_prune_genome()))
        @test isempty(p.impacts)
        # avec une analyse qui échoue, le message le dit ; sans son, rien à mesurer
        Ressac._PRUNE_ANALYZE[] = gs -> error("nrt: sclang introuvable")
        Ressac._synthdoc_measure_impacts!(p)
        @test !p.measuring && isempty(p.impacts) && any(l -> occursin("indisponible", l), p.explain_lines)
        Ressac._synthdoc_set_genome!(p, nothing)
        @test !Ressac._synthdoc_measure_impacts!(p) && isempty(p.explain_lines)
    finally
        Ressac._PRUNE_ANALYZE[] = old_an; Ressac._WAVE_SYNC[] = old_sync
    end
end

@testset "élagage — :explain montre la section, :prune réécrit le bloc @synth de l'éditeur" begin
    old_an = Ressac._PRUNE_ANALYZE[]
    Ressac._PRUNE_ANALYZE[] = _fake_analyze
    old_wr = Ressac._WAVE_RENDER[]
    dir = mktempdir(); mkpath(joinpath(dir, "plugins", "user-synths")); oldwd = pwd(); cd(dir)
    try
        app = Ressac.RessacApp(; scheduler = Ressac.Scheduler(MockOSCClient(); cps = 0.5))
        tb = Tachikoma.TestBackend(120, 40)
        frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 120, 40), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
        Tachikoma.view(app, frame); Ressac._PANE_MODE.active = false; Ressac._active_editor(app).mode = :normal
        ex(cmd) = (Tachikoma.update!(app, Tachikoma.KeyEvent(':')); foreach(c -> Tachikoma.update!(app, Tachikoma.KeyEvent(c)), cmd); Tachikoma.update!(app, Tachikoma.KeyEvent(:enter)))
        Ressac._WAVE_RENDER[] = g -> (Float32[0.0f0, 0.1f0], 44100)
        ex("synth truc")
        snd = Ressac._current_sound(app)
        @test snd !== nothing && snd.name == "truc"
        ed = snd.code_editor
        # Le texte entier, curseur sur la ligne `row` (dans le son).
        settext(t, row) = (Tachikoma.set_text!(ed, t); ed.cursor_row = row; ed.cursor_col = 0; ed.mode = :normal)
        src = "# mon synth\n@synth :truc (freq=220, sustain=0.5) begin\n" *
              "    a = saw(:freq) |> rlpf(800, 0.3) |> tanh_drive(1) |> fold2(1) |> fold2(1)\n" *
              "    a + ugen(:Saw, 0.0)\nend\n\n# note finale\n"
        settext(src, 3)
        # :explain sur le son du curseur : l'onglet explication de la DOC, avec ÉLAGAGE et ses indices
        ex("explain")
        sdoc = Ressac._sound_doc(app)
        @test sdoc !== nothing && sdoc.mode === :explain
        @test Ressac._focused_pane_impl(app) === sdoc
        lines = sdoc.explain_lines
        @test any(l -> occursin("ÉLAGAGE", l), lines) && any(l -> occursin("fréquence 0", l), lines)
        Ressac._focus_patterns!(app)
        # :prune réécrit le bloc, garde les commentaires autour
        ex("prune")
        txt = Tachikoma.text(ed)
        @test startswith(txt, "# mon synth\n@synth :truc") && occursin("# note finale", txt)
        @test count("fold2", txt) == 1 || !occursin("Fold2", txt) || count("Fold2", txt) <= 1
        @test !occursin("ugen(:Saw, 0.0)", txt)
        # deux lignes au journal : ce que la structure a retiré, puis le verdict de la mesure
        @test occursin("|> rlpf(", txt)
        @test any(l -> occursin(":prune — ", l) && occursin("retiré", l) && occursin("d'après la structure", l), app.logs[(end - 1):end])
        @test occursin(":prune — rien de plus sous", app.logs[end])
        g2 = Ressac.genome_from_dsl(txt)
        @test g2 !== nothing && isempty(Ressac.static_prune_hints(g2))     # plus rien à élaguer
        # remplacement de bloc : pas de @synth → texte inchangé
        @test Ressac.replace_synth_block("x = 1\n", "@synth :y (freq=1) saw(:freq)") == "x = 1\n"
        # sans mesure disponible, les indices statiques suffisent
        Ressac._PRUNE_ANALYZE[] = gs -> error("nrt: sclang introuvable")
        settext(src, 3)
        ex("prune")
        @test !occursin("ugen(:Saw, 0.0)", Tachikoma.text(ed)) && occursin("mesure indisponible", app.logs[end])
        @test startswith(Tachikoma.text(ed), "# mon synth\n@synth :truc") && occursin("# note finale", Tachikoma.text(ed))
        # rien à retirer : le journal le dit, le texte ne bouge pas
        clean = "@synth :truc (freq=220) saw(:freq) |> rlpf(800, 0.3)\n"
        settext(clean, 1); ex("prune")
        @test Tachikoma.text(ed) == clean && occursin("rien", app.logs[end])
        # hors d'un son : :prune demande d'y poser le curseur, et ne touche à rien
        settext("@d1 p\"bd\"\n\n" * clean, 1); ex("prune")
        @test Tachikoma.text(ed) == "@d1 p\"bd\"\n\n" * clean && occursin("[WARN] :prune — pose le curseur sur un son", app.logs[end])
    finally
        cd(oldwd); Ressac._PRUNE_ANALYZE[] = old_an; Ressac._WAVE_RENDER[] = old_wr
    end
end
