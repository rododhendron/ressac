# Voir ce qui joue : référence de slot, visualiseur de notes, aperçu en
# bout de ligne.
using Test
using Ressac
using Tachikoma

if !@isdefined(_NvMock)
    mutable struct _NvMock
        sent::Vector{Vector{UInt8}}
    end
    _NvMock() = _NvMock(Vector{UInt8}[])
    Ressac.send_osc(c::_NvMock, bytes::Vector{UInt8}) = push!(c.sent, bytes)
end

function _nv_app(; w = 120, h = 30)
    app = Ressac.RessacApp(; scheduler = Ressac.Scheduler(_NvMock(); cps = 0.5))
    tb = Tachikoma.TestBackend(w, h)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, w, h),
                            Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    Ressac._PANE_MODE.active = false
    Ressac._active_editor(app).mode = :normal
    return app, tb, frame
end
function _nv_screen(app, tb, frame, h)
    Tachikoma.reset!(tb.buf); Tachikoma.view(app, frame)
    join((Tachikoma.row_text(tb, y) for y in 1:h), "\n")
end

@testset "slot(n) — désigner une voix au lieu de recopier son rythme" begin
    mock = _NvMock()
    sched = Ressac.Scheduler(mock; cps = 0.5)
    old = Ressac._LIVE_SCHEDULER[]
    Ressac._LIVE_SCHEDULER[] = sched
    try
        @test isempty(slot(1)(0//1, 1//1))               # slot vide : silencieux
        set_pattern!(sched, :d1, pat("bd(3,8)"))
        @test [ev.start for ev in slot(1)(0//1, 1//1)] == [0//1, 3//8, 3//4]
        @test length(slot(:d1)(0//1, 1//1)) == 3
        @test length(slot("d1")(0//1, 1//1)) == 3
        @test length(slot("1")(0//1, 1//1)) == 3
        # il suit l'édition du slot, sans qu'on refasse le branchement
        ducked = pat("hh*8") |> duck(slot(1); depth = 0.9, release = 1//4)
        g1 = [ev.value[:gain] for ev in sort(ducked(0//1, 1//1); by = e -> e.start)]
        set_pattern!(sched, :d1, pat("bd*2"))
        g2 = [ev.value[:gain] for ev in sort(ducked(0//1, 1//1); by = e -> e.start)]
        @test g1 != g2
        @test [ev.start for ev in slot(1)(0//1, 1//1)] == [0//1, 1//2]
        # et se compose comme n'importe quel pattern
        @test length((slot(1) |> fast(2))(0//1, 1//1)) == 4
        @test [ev.start for ev in (pat("hh*4") |> avoid(slot(1)))(0//1, 1//1)] == [1//4, 3//4]
    finally
        Ressac._LIVE_SCHEDULER[] = old
    end
end

@testset "pane notes — hauteurs, couloirs de percussion, tête de lecture" begin
    app, tb, frame = _nv_app()
    old = Ressac._LIVE_SCHEDULER[]
    Ressac._LIVE_SCHEDULER[] = app.scheduler
    try
        app.scheduler.t_start = time() - 4.0
        set_pattern!(app.scheduler, :d1, pat("bd*4"))
        set_pattern!(app.scheduler, :d2, :pad |> n("0 4 7 12"))
        Ressac._open_notes_pane!(app)
        np = Ressac._focused_pane_impl(app)
        @test np isa Ressac.NotesPane
        scr = _nv_screen(app, tb, frame, 30)
        @test occursin("NOTES", scr)
        @test occursin("d1", scr) && occursin("d2", scr)     # légende
        @test occursin("bd", scr)                            # couloir de percussion nommé
        @test occursin("█", scr)
        # la hauteur : une note se lit, une percussion non
        @test Ressac._note_row(Dict(:note => 7)) == 67.0
        @test Ressac._note_row(Dict(:n => -12)) == 48.0
        @test Ressac._note_row(Dict(:freq => 440)) ≈ 69.0
        @test Ressac._note_row(Dict(:s => :bd)) === nothing
        @test Ressac._note_row(:bd) === nothing
        @test Ressac._note_row(Dict(:note => 0, :n => 5)) == 60.0   # note l'emporte
        # la fenêtre se règle et reste bornée
        s0 = np.span
        Tachikoma.update!(app, Tachikoma.KeyEvent('+')); @test np.span == s0 * 2
        Tachikoma.update!(app, Tachikoma.KeyEvent('-')); @test np.span == s0
        for _ in 1:12; Tachikoma.update!(app, Tachikoma.KeyEvent('-')); end
        @test np.span >= 1//4
        for _ in 1:12; Tachikoma.update!(app, Tachikoma.KeyEvent('+')); end
        @test np.span <= 32
        # les couloirs de percussion aussi
        r0 = np.perc_rows
        Tachikoma.update!(app, Tachikoma.KeyEvent('k')); @test np.perc_rows == r0 + 1
        Tachikoma.update!(app, Tachikoma.KeyEvent('j')); @test np.perc_rows == r0
        # une seconde ouverture focalise au lieu de dupliquer
        Ressac._open_notes_pane!(app)
        panes = [t for leaf in Ressac._all_leaves(Ressac.current_workspace(app.workspaces).tree)
                 for t in leaf.tabs if t isa Ressac.NotesPane]
        @test length(panes) == 1
        # sans rien qui joue, la pane le dit au lieu de dessiner du vide
        hush!(app.scheduler)
        @test occursin("Rien ne joue", _nv_screen(app, tb, frame, 30))
    finally
        Ressac._LIVE_SCHEDULER[] = old
    end
end

@testset "aperçu en bout de ligne — ce que le slot joue vraiment" begin
    app, tb, frame = _nv_app(; w = 110, h = 20)
    old = Ressac._LIVE_SCHEDULER[]
    Ressac._LIVE_SCHEDULER[] = app.scheduler
    try
        app.scheduler.t_start = time()
        ed = Ressac._active_editor(app)
        Tachikoma.set_text!(ed, "@d1 p\"bd(3,8)\"\n@d2 :pad |> n(fib(5))\n@d3 :pad |> n(\"0 2 4\") |> scale(:minor)\n# @d4 muet")
        set_pattern!(app.scheduler, :d1, pat("bd(3,8)"))
        set_pattern!(app.scheduler, :d2, :pad |> n(fib(5)))
        set_pattern!(app.scheduler, :d3, :pad |> n("0 2 4") |> scale(:minor))
        rows = split(_nv_screen(app, tb, frame, 20), "\n")
        @test any(r -> occursin("x·····x·····x···", r), rows)      # le rythme
        @test any(r -> occursin("♪ 1 1 2 3 5", r), rows)           # les notes d'une fonction
        @test any(r -> occursin("♪ 0 3 7", r), rows)               # la gamme appliquée
        muet = rows[findfirst(r -> occursin("@d4 muet", r), rows)]
        @test !occursin("♪", muet) && !occursin("▏", muet)         # ligne commentée : rien
        # :inline coupe et rallume
        app.inline_preview = false
        rows = split(_nv_screen(app, tb, frame, 20), "\n")
        @test !any(r -> occursin("♪ 1 1 2 3 5", r), rows)
        app.inline_preview = true
        # un slot non évalué n'affiche rien
        Tachikoma.set_text!(ed, "@d9 p\"cp*4\"")
        rows = split(_nv_screen(app, tb, frame, 20), "\n")
        @test !any(r -> occursin("▏x", r) && occursin("@d9", r), rows)
    finally
        Ressac._LIVE_SCHEDULER[] = old
    end
end

@testset "_preview_of — hauteurs si présentes, grille sinon" begin
    ev(a, b, v) = Ressac.Event{Any}(Rational{Int64}(a), Rational{Int64}(b), v)
    notes = [ev(0, 1//2, Dict{Symbol,Any}(:note => 0)), ev(1//2, 1, Dict{Symbol,Any}(:note => 7))]
    @test Ressac._preview_of(notes, 30) == "♪ 0 7"
    drums = [ev(0, 1//4, :bd), ev(1//2, 3//4, :sn)]
    @test Ressac._preview_of(drums, 30) == "▏x·······x·······"
    @test Ressac._preview_of(drums, 12) == "▏x···x···"        # moins de place, moins de pas
    @test Ressac._preview_of([], 30) == ""
    @test length(Ressac._preview_of(notes, 4)) <= 4           # tronqué à la place dispo
end

@testset "bandeau des slots — hauteur dynamique, muet, clic, bascule" begin
    app, tb, frame = _nv_app(; w = 100, h = 22)
    old = Ressac._LIVE_SCHEDULER[]
    Ressac._LIVE_SCHEDULER[] = app.scheduler
    empty!(Ressac._APP_MUTED_PATTERNS)
    try
        # rien de chargé : pas de bandeau, la disposition ne bouge pas
        @test app.rack_visible
        @test Ressac._rack_height(app) == 0
        scr0 = _nv_screen(app, tb, frame, 22)
        @test occursin("PATTERNS", split(scr0, "\n")[2])
        # un slot par ligne
        app.scheduler.t_start = time() - 1.3
        set_pattern!(app.scheduler, :d1, pat("bd(3,8)"))
        @test Ressac._rack_height(app) == 1
        set_pattern!(app.scheduler, :d2, :pad |> n("0 4 7"))
        set_pattern!(app.scheduler, :d5, pat("cp*2"))
        @test Ressac._rack_height(app) == 3
        rows = split(_nv_screen(app, tb, frame, 22), "\n")
        @test occursin("d1", rows[2]) && occursin("d2", rows[3]) && occursin("d5", rows[4])
        @test occursin("bd", rows[2]) && occursin("pad", rows[3])
        @test occursin("x·····x·····x···", rows[2])       # le motif du cycle
        @test occursin("PATTERNS", rows[5])                # les panes ont été poussées
        # un slot coupé reste visible, avec sa marque
        Ressac._mute_pattern_slot!(app, :d2)
        @test Ressac._rack_height(app) == 3                # toujours trois lignes
        rows = split(_nv_screen(app, tb, frame, 22), "\n")
        @test occursin("⏸", rows[3]) && occursin("d2", rows[3])
        @test occursin("▸", rows[2])
        # un clic sur la ligne coupe, un deuxième remet
        y_d1 = 2
        @test Ressac._rack_click!(app, y_d1)
        @test !haskey(app.scheduler.patterns, :d1)
        @test Ressac._rack_click!(app, y_d1)
        @test haskey(app.scheduler.patterns, :d1)
        @test !Ressac._rack_click!(app, 21)                # hors bandeau
        # la bascule
        Ressac._toggle_rack!(app)
        @test !app.rack_visible && Ressac._rack_height(app) == 0
        @test occursin("PATTERNS", split(_nv_screen(app, tb, frame, 22), "\n")[2])
        Ressac._toggle_rack!(app)
        @test app.rack_visible
        # au-delà du maximum, une ligne récapitule
        for i in 6:16; set_pattern!(app.scheduler, Symbol("d", i), pat("bd")); end
        h = Ressac._rack_height(app)
        @test 2 <= h <= Ressac._RACK_MAX_ROWS + 1
        rows = split(_nv_screen(app, tb, frame, 22), "\n")
        @test any(r -> occursin("autres slots", r), rows)   # le reste est compté
        @test count(r -> occursin("│x", r) || occursin("│·", r), rows) < 16
        # et jamais plus de la moitié de la fenêtre
        @test Ressac._rack_height(app, 6) <= 3
    finally
        hush!(app.scheduler)
        empty!(Ressac._APP_MUTED_PATTERNS)
        Ressac._LIVE_SCHEDULER[] = old
    end
end
