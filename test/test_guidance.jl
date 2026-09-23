# Guidage de la création : pane wiki, pane doc (:doc, K), placement des
# snippets Espace, slot pré-rempli, indices de la barre, sons inconnus.
using Test
using Ressac
using Tachikoma

if !@isdefined(_GdMock)
    mutable struct _GdMock
        sent::Vector{Vector{UInt8}}
    end
    _GdMock() = _GdMock(Vector{UInt8}[])
    Ressac.send_osc(c::_GdMock, bytes::Vector{UInt8}) = push!(c.sent, bytes)
end

# La disposition PLAY par défaut ouvre wiki + doc à droite (voir
# `_play_side_panes!`). Les tests de mécanique de panes (split, fermeture,
# zoom, comptage) veulent un point de départ à une seule pane : on replie
# l'arbre sur l'éditeur, explicitement, sans état global partagé.
function _only_patterns!(app)
    ws = Ressac.current_workspace(app.workspaces)
    ws === nothing && return app
    for leaf in Ressac._all_leaves(ws.tree)
        if any(t -> t isa Ressac.EditorPane, leaf.tabs)
            ws.tree = leaf
            ws.focused_pane = leaf.id
            break
        end
    end
    return app
end

function _gd_app()
    sched = Ressac.Scheduler(_GdMock(); cps = 0.5)
    app = Ressac.RessacApp(; scheduler = sched)
    tb = Tachikoma.TestBackend(160, 40)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 160, 40),
                            Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    _only_patterns!(app)
    Ressac._PANE_MODE.active = false
    Ressac._active_editor(app).mode = :normal
    return app, tb, frame
end
_gdkey(app, c::Char) = Tachikoma.update!(app, Tachikoma.KeyEvent(c))
_gdkey(app, s::Symbol) = Tachikoma.update!(app, Tachikoma.KeyEvent(s))
_gdex(app, cmd) = (_gdkey(app, ':'); foreach(c -> _gdkey(app, c), cmd); _gdkey(app, :enter))
function _gdscreen(app, tb, frame)
    Tachikoma.reset!(tb.buf); Tachikoma.view(app, frame)
    join((Tachikoma.row_text(tb, y) for y in 1:40), "\n")
end
_gdpanes(app, T) = [t for leaf in Ressac._all_leaves(Ressac.current_workspace(app.workspaces).tree) for t in leaf.tabs if t isa T]

@testset "wiki en pane — :wiki, :wiki <page>, navigation, :q" begin
    app, tb, frame = _gd_app()
    _gdex(app, "wiki")
    @test app.modal === :none
    wp = Ressac._focused_pane_impl(app)
    @test wp isa Ressac.WikiPane && !isempty(wp.pages)
    @test length(_gdpanes(app, Ressac.EditorPane)) == 1            # les patterns sont toujours là
    scr = _gdscreen(app, tb, frame)
    @test occursin("WIKI · 1/", scr) && occursin("PATTERNS", scr)
    n0 = wp.idx
    _gdkey(app, 'n'); @test wp.idx == n0 + 1
    _gdkey(app, 'p'); @test wp.idx == n0
    _gdkey(app, 'j'); _gdkey(app, 'j'); @test wp.scroll == 2
    _gdkey(app, 'G'); @test wp.scroll == Ressac._wiki_last(wp)
    _gdkey(app, 'g'); @test wp.scroll == 0
    # :wiki tidal → la page dont le titre contient « tidal », sans doublon de pane
    _gdex(app, "wiki tidal")
    @test length(_gdpanes(app, Ressac.WikiPane)) == 1
    @test occursin("tidal", lowercase(wp.pages[wp.idx].title))
    _gdex(app, "wiki 2"); @test wp.idx == 2
    _gdex(app, "wiki zzz-inconnue"); @test occursin("pas de page", app.logs[end])
    @test Ressac._wiki_goto!(wp, "") == false
    _gdex(app, "q")                                                 # ferme la pane wiki
    @test isempty(_gdpanes(app, Ressac.WikiPane)) && !app.quit
    # le scope :wiki est dans l'aide, le modal a disparu
    @test :wiki in Ressac._PANE_SCOPES && !haskey(Ressac._MODAL_SCOPES, :wiki)
end

@testset "doc en pane — :doc et K sans voler le focus" begin
    # les fiches du plugin core (headless : pas de découverte de plugins)
    Ressac._handle_docs(joinpath(@__DIR__, "..", "plugins", "core"), Dict("dir" => "docs"), "core")
    app, tb, frame = _gd_app()
    ed = Ressac._active_editor(app)
    ws = Ressac.current_workspace(app.workspaces)
    focus0 = ws.focused_pane
    _gdex(app, "doc gain")
    dp = _gdpanes(app, Ressac.DocPane)
    @test length(dp) == 1 && dp[1].name == "gain"
    @test ws.focused_pane == focus0                                 # l'éditeur garde le focus
    @test occursin("[doc] gain", app.logs[end])
    scr = _gdscreen(app, tb, frame)
    @test occursin("DOC · gain", scr) && occursin("exemples", scr)
    # K sur un mot : la même pane change de fiche
    Tachikoma.set_text!(ed, "@d1 p\"bd hh\" |> every(4, rev) |> lpf(800)")
    ed.cursor_row = 1; ed.cursor_col = 20                           # sur « every »
    _gdkey(app, 'K')
    @test length(_gdpanes(app, Ressac.DocPane)) == 1 && dp[1].name == "every"
    ed.cursor_col = 22                                              # sur « 4 » → appel englobant every
    _gdkey(app, 'K')
    @test dp[1].name == "every"
    ed.cursor_col = 36                                              # sur « lpf »
    _gdkey(app, 'K')
    @test dp[1].name == "lpf"
    Tachikoma.set_text!(ed, ""); ed.cursor_row = 1; ed.cursor_col = 0
    _gdkey(app, 'K')
    @test occursin("pose le curseur", app.logs[end])
    _gdex(app, "doc zzzinconnu")
    @test occursin("aucune entrée", app.logs[end])
    @test Ressac._wrap_text("un deux trois quatre", 9) == ["un deux", "trois", "quatre"]
    @test Ressac._wrap_text("", 5) == [""]
end

@testset "snippets Espace — placement en fin de bloc / sous le bloc, slot pré-rempli" begin
    app, tb, frame = _gd_app()
    ed = Ressac._active_editor(app)
    # maillon |> : en fin de ligne, même curseur au début
    Tachikoma.set_text!(ed, "@d1 p\"bd hh\"\n  |> gain(0.8)\n\n@d3 p\"sn\"")
    ed.cursor_row = 1; ed.cursor_col = 0
    _gdkey(app, ' '); _gdkey(app, 'l')
    lines = split(Tachikoma.text(ed), '\n')
    @test lines[2] == "  |> gain(0.8) |> lpf()"                     # fin du bloc (ligne |> suivante)
    @test ed.cursor_row == 2 && app.placeholder_active
    @test ed.cursor_col == length("  |> gain(0.8) |> lpf(")
    _gdkey(app, :escape)
    # ligne complète @dN : sous le bloc, slot libre = 2
    ed.cursor_row = 1; ed.cursor_col = 3
    @test Ressac._next_free_slot(ed) == 2
    _gdkey(app, ' '); _gdkey(app, 'd')
    lines = split(Tachikoma.text(ed), '\n')
    @test lines[3] == "@d2 p\"\"" && ed.cursor_row == 3
    @test ed.cursor_col == length("@d2 p\"") && app.placeholder_idx == 1
    _gdkey(app, :escape)
    # ligne vide : sur place ; commentée compte comme occupée
    Tachikoma.set_text!(ed, "# @d1 p\"bd\"\n")
    ed.cursor_row = 2; ed.cursor_col = 0
    _gdkey(app, ' '); _gdkey(app, 'd')
    @test split(Tachikoma.text(ed), '\n')[2] == "@d2 p\"\""
    _gdkey(app, :escape)
    # fragment : au curseur
    Tachikoma.set_text!(ed, "@d1 p\"bd \""); ed.cursor_row = 1; ed.cursor_col = 9
    _gdkey(app, ' '); _gdkey(app, 'E')
    @test startswith(Tachikoma.text(ed), "@d1 p\"bd (,)\"")
    _gdkey(app, :escape)
    # jersey : slot pré-rempli et le trou restant sur gain
    Tachikoma.set_text!(ed, ""); ed.cursor_row = 1; ed.cursor_col = 0
    _gdkey(app, ' '); _gdkey(app, 'J')
    @test Tachikoma.text(ed) == "@d1 p\"bd(3,8)\" |> gain()"
    @test length(app.placeholder_cols) == 1 && ed.cursor_col == length("@d1 p\"bd(3,8)\" |> gain(")
    @test Ressac._prefill_slot("|> gain(\$1)", ed) == "|> gain(\$1)"
    @test Ressac._snippet_kind("|> x") === :chain && Ressac._snippet_kind("@d\$1") === :block &&
          Ressac._snippet_kind("rev") === :inline
end

@testset "indices de création dans la barre du bas" begin
    app, tb, frame = _gd_app()
    ed = Ressac._active_editor(app)
    Tachikoma.set_text!(ed, "@d1 p\"bd\"\n"); ed.cursor_row = 2; ed.cursor_col = 0
    @test occursin("vide :", Ressac._creation_hint(app))
    @test occursin("Espace d slot", _gdscreen(app, tb, frame))
    ed.cursor_row = 1; ed.cursor_col = 1
    @test Ressac._creation_hint(app) === nothing
    Tachikoma.set_text!(ed, "@d1 p\"bd\" |>"); ed.cursor_row = 1; ed.cursor_col = 12
    @test Ressac._creation_hint(app) === nothing                    # en normal : rien
    ed.mode = :insert
    @test occursin("|> gain", Ressac._creation_hint(app))
    ed.mode = :normal
end

@testset "sons inconnus signalés à l'évaluation" begin
    @test Ressac._unknown_sounds(String[]) == String[]
    Ressac.register_sample!(Ressac.SampleEntry(:gdkick, "test", "", String[], Dict{String,Any}()))
    try
        @test Ressac._unknown_sounds(["@d1 p\"gdkick zzz:2 ~ _\"", "@d2 :x |> s(\"gdkick yyy\")"]) == ["zzz", "yyy"]
        @test Ressac._unknown_sounds(["@d1 :pad |> n(\"c e g\")"]) == String[]      # les notes ne sont pas des sons
        app, tb, frame = _gd_app()
        old = Ressac._LIVE_SCHEDULER[]
        Ressac._LIVE_SCHEDULER[] = app.scheduler
        try
            Tachikoma.set_text!(Ressac._active_editor(app), "@d1 p\"gdkick zzz\"")
            _gdkey(app, 'e')
            @test any(l -> occursin("son inconnu : « zzz »", l), app.logs)
        finally
            Ressac._LIVE_SCHEDULER[] = old
        end
    finally
        delete!(Ressac._SAMPLE_REGISTRY, :gdkick)
    end
end

@testset "navigateur de sons — grille 2D et recherche explicite" begin
    app, tb, frame = _gd_app()
    names = [Symbol("gd$i") for i in 1:12]
    for nm in names
        Ressac.register_sample!(Ressac.SampleEntry(nm, "test", "", String[], Dict{String,Any}()))
    end
    Ressac.register_sample!(Ressac.SampleEntry(:gdjazz, "test", "", String[], Dict{String,Any}()))
    try
        _gdex(app, "browse")
        @test app.modal === :browse && !app.browser_search_mode
        scr = _gdscreen(app, tb, frame)
        @test occursin("/ pour chercher", scr) && occursin("sons", scr)
        n = length(Ressac._browser_entries(app))
        @test n >= 13
        @test app.browser_cols >= 1                       # la grille a été mesurée au rendu
        # navigation 2D : l/h d'une case, j/k d'une ligne
        app.browser_cursor = 1
        _gdkey(app, 'l'); @test app.browser_cursor == 2
        _gdkey(app, 'h'); @test app.browser_cursor == 1
        _gdkey(app, 'j'); @test app.browser_cursor == 1 + app.browser_cols
        _gdkey(app, 'k'); @test app.browser_cursor == 1
        _gdkey(app, 'k'); @test app.browser_cursor == 1    # borné en haut
        _gdkey(app, 'G'); @test app.browser_cursor == n
        _gdkey(app, 'l'); @test app.browser_cursor == n    # borné en bas
        _gdkey(app, 'g'); @test app.browser_cursor == 1
        # recherche : « jazz » contient j et a, qui sont des raccourcis hors recherche
        _gdkey(app, '/')
        @test app.browser_search_mode
        for c in "jazz"; _gdkey(app, c); end
        @test app.browser_query == "jazz"
        @test [String(e.name) for e in Ressac._browser_entries(app)] == ["gdjazz"]
        @test occursin("⌕ jazz", _gdscreen(app, tb, frame))
        _gdkey(app, :enter)                                # valide : filtre gardé, nav revient
        @test !app.browser_search_mode && app.browser_query == "jazz"
        _gdkey(app, :escape)                               # 1er Esc efface le filtre
        @test isempty(app.browser_query) && app.modal === :browse
        _gdkey(app, :escape)                               # 2e ferme
        @test app.modal === :none
        # Esc pendant la recherche efface aussi
        _gdex(app, "browse"); _gdkey(app, '/'); _gdkey(app, 'k')
        @test app.browser_query == "k"
        _gdkey(app, :escape)
        @test !app.browser_search_mode && isempty(app.browser_query) && app.modal === :browse
        _gdkey(app, :escape)
    finally
        for nm in names; delete!(Ressac._SAMPLE_REGISTRY, nm); end
        delete!(Ressac._SAMPLE_REGISTRY, :gdjazz)
    end
end

@testset "variables et suites Julia dans le buffer" begin
    app, tb, frame = _gd_app()
    old = Ressac._LIVE_SCHEDULER[]
    Ressac._LIVE_SCHEDULER[] = app.scheduler
    try
        ed = Ressac._active_editor(app)
        # E évalue aussi ce qui n'est pas un slot : variables, cps!, fonctions
        Tachikoma.set_text!(ed, """
        basse = p"bd ~ bd bd"
        motif = [0, 3, 7]
        @d1 basse |> gain(0.9)
        @d2 :pad |> n(motif)
        """)
        _gdkey(app, 'E')
        # Julia 1.12 partitionne les bindings par âge de monde : une variable
        # créée par Core.eval n'est pas visible du code déjà compilé (ce
        # testset), mais l'est des évaluations suivantes — comme dans la TUI.
        @test Core.eval(Main, :(basse isa Ressac.Pattern))
        @test Core.eval(Main, :(motif == [0, 3, 7]))
        @test haskey(app.scheduler.patterns, :d1) && haskey(app.scheduler.patterns, :d2)
        @test any(l -> occursin("définition", l), app.logs)
        # une ligne commentée reste ignorée
        Tachikoma.set_text!(ed, "# zzz_pas_defini = 1\n@d1 p\"bd\"")
        _gdkey(app, 'E')
        @test !Core.eval(Main, :(isdefined(Main, :zzz_pas_defini)))
        # une erreur dans une définition est signalée et n'empêche pas les slots
        Tachikoma.set_text!(ed, "oups = (\n@d1 p\"bd\"")
        _gdkey(app, 'E')
        @test any(l -> occursin("[ERROR]", l), app.logs)
    finally
        Ressac._LIVE_SCHEDULER[] = old
    end
end

@testset "listes, ranges Julia et gammes dans les contrôles" begin
    nv(p) = [get(ev.value, :n, nothing) for ev in sort(p(0//1, 1//1); by = e -> e.start)]
    @test nv(:pad |> n(0:3)) == [0, 1, 2, 3]
    @test nv(:pad |> n([0, 3, 7])) == [0, 3, 7]
    @test nv(:pad |> n(2 .^ (0:2))) == [1, 2, 4]
    @test [ev.start for ev in (:pad |> n(0:3))(0//1, 1//1)] == [0//1, 1//4, 1//2, 3//4]
    @test [round(get(ev.value, :cutoff, 0)) for ev in (:bd |> lpf(geom(200, 6400, 3)))(0//1, 1//1)] ==
          [200.0, 1131.0, 6400.0]
    @test length(geom(100, 200, 1)) == 1
    @test_throws ArgumentError geom(0, 100, 4)
    @test [get(ev.value, :room, 0) for ev in (:bd |> set(:room, range(0, 1, length = 3)))(0//1, 1//1)] ==
          [0.0, 0.5, 1.0]
    # gammes : degré → demi-tons
    notes(p) = [get(ev.value, :note, nothing) for ev in sort(p(0//1, 1//1); by = e -> e.start)]
    @test notes(:pad |> n(0:3) |> scale(:major)) == [0.0, 2.0, 4.0, 5.0]
    @test notes(:pad |> degree("0 2 4") |> scale(:minor)) == [0.0, 3.0, 7.0]
    @test :major in list_scales() && lookup_scale(:major) !== nothing
    @test scale_to_semitones(lookup_scale(:major), 4) == 7.0
    @test Ressac.lookup_doc("scale") !== nothing && Ressac.lookup_doc("degree") !== nothing
end
