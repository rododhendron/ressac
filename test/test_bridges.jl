include(joinpath(@__DIR__, "helpers.jl"))
# Ponts son ⟷ patterns : workspaces PLAY / DESIGN / EXPLORE, gs, U,
# :synth <nom> depuis la librairie, U, export et M de l'explorateur.
using Test
using Ressac
import Tachikoma

function _br_app()
    sched = Ressac.Scheduler(MockOSCClient(); cps = 0.5)
    app = Ressac.RessacApp(; scheduler = sched)
    tb = Tachikoma.TestBackend(120, 40)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 120, 40),
                            Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    _only_patterns!(app)
    Ressac._PANE_MODE.active = false
    Ressac._active_editor(app).mode = :normal
    return app, tb, frame
end
_bkey(app, c::Char) = Tachikoma.update!(app, Tachikoma.KeyEvent(c))
_bkey(app, s::Symbol) = Tachikoma.update!(app, Tachikoma.KeyEvent(s))
_bex(app, cmd) = (_bkey(app, ':'); foreach(c -> _bkey(app, c), cmd); _bkey(app, :enter))
# Où le joueur travaille : le contexte de la pane focalisée.
_bws(app) = Dict(:play => "PLAY", :design => "DESIGN", :explore => "EXPLORE")[Ressac._workspace_mode(app)]
function _bscreen(app, tb, frame)
    Tachikoma.reset!(tb.buf); Tachikoma.view(app, frame)
    join((Tachikoma.row_text(tb, y) for y in 1:40), "\n")
end
# Sandbox : les ponts écrivent dans plugins/user-synths → on travaille
# dans un répertoire temporaire (pwd() est la racine des chemins).
function _in_sandbox(f)
    dir = mktempdir()
    mkpath(joinpath(dir, "plugins", "user-synths"))
    old = pwd()
    cd(dir)
    try
        f()
    finally
        cd(old)
    end
end

@testset "écran unique — les patterns à gauche, un volet à droite, l'explorateur par-dessus" begin
    app, tb, frame = _br_app()
    @test length(app.workspaces.workspaces) == 1             # un seul écran
    @test _bws(app) == "PLAY" && app.volet === :fiche
    @test Ressac._focused_role(app) === :patterns
    scr = _bscreen(app, tb, frame)
    @test occursin("PATTERNS", scr) && !occursin("DESIGN", scr) && !occursin("EXPLORE", scr)
    patterns = Tachikoma.text(Ressac._patterns_editor(app))
    _bex(app, "son")
    @test _bws(app) == "DESIGN" && app.volet === :son
    @test Ressac._focused_role(app) === :synth               # sketch synth pré-rempli
    @test occursin("@synth :sketch", Tachikoma.text(Ressac._active_editor(app)))
    @test occursin("PATTERNS", _bscreen(app, tb, frame))     # les patterns restent à l'écran
    _bex(app, "explore")
    @test _bws(app) == "EXPLORE"
    @test Ressac._focused_pane_impl(app) isa Ressac.SynthExplorerPane
    @test occursin("EXPLORER", _bscreen(app, tb, frame))
    _bex(app, "back")
    @test _bws(app) == "PLAY" && app.volet === :fiche && app.zoom_leaf == 0
    @test Tachikoma.text(Ressac._patterns_editor(app)) == patterns
    # Un volet déjà ouvert est gardé : le son retrouve son texte.
    _bex(app, "son")
    Tachikoma.set_text!(Ressac._active_editor(app), "@synth :sketch (freq=220) saw(:freq)")
    _bex(app, "wiki"); @test app.volet === :wiki
    _bex(app, "son")
    @test occursin("saw(:freq)", Tachikoma.text(Ressac._active_editor(app)))
    # :q ferme le volet, puis seulement quitte.
    _bex(app, "q"); @test app.volet === :fiche && !app.quit
    @test Ressac._focused_role(app) === :patterns
end

@testset ":synth <nom> ouvre la recette de librairie (copie éditable), pas un starter vide" begin
    _in_sandbox() do
        app, tb, frame = _br_app()
        _bex(app, "synth kick")
        @test Ressac._focused_role(app) === :synth
        txt = Tachikoma.text(Ressac._active_editor(app))
        @test occursin("env_perc", txt)                        # la recette, pas sin_osc(:freq) seul
        @test occursin("@synth :kick", txt)
        @test isfile(joinpath(pwd(), "plugins", "user-synths", "kick.jl"))
        # un nom inconnu garde le starter
        _bex(app, "synth zorglub")
        @test occursin("@synth :zorglub", Tachikoma.text(Ressac._active_editor(app)))
        @test !occursin("env_perc", Tachikoma.text(Ressac._active_editor(app)))
    end
end

@testset "gs — ouvre le synth sous le curseur dans DESIGN ; mot inconnu → message" begin
    _in_sandbox() do
        app, tb, frame = _br_app()
        ed = Ressac._active_editor(app)
        Tachikoma.set_text!(ed, "@d1 p\"kick*4\"\n@d2 p\"zorglub\"")
        ed.cursor_row = 1; ed.cursor_col = 8                  # sur « kick »
        _bkey(app, 'g'); _bkey(app, 's')
        @test _bws(app) == "DESIGN"
        @test Ressac._focused_role(app) === :synth
        @test Ressac._current_synth_tab(app).name == "kick"
        @test occursin("env_perc", Tachikoma.text(Ressac._active_editor(app)))
        # retour, mot inconnu
        _bex(app, "back")
        ed = Ressac._active_editor(app)
        ed.cursor_row = 2; ed.cursor_col = 8                  # sur « zorglub »
        n0 = length(app.logs)
        _bkey(app, 'g'); _bkey(app, 's')
        @test _bws(app) == "PLAY"
        @test occursin("pas un synth connu", app.logs[end])
    end
end

@testset "U — depuis une pane synth : sauve, puis @dN p\"nom*4\" dans PLAY" begin
    _in_sandbox() do
        app, tb, frame = _br_app()
        _bex(app, "synth kick")
        @test _bws(app) == "DESIGN"                            # :synth vit dans DESIGN (pont)
        _bkey(app, 'U')
        @test _bws(app) == "PLAY"
        @test Ressac._focused_role(app) === :patterns
        ed = Ressac._active_editor(app)
        txt = Tachikoma.text(ed)
        @test occursin("@d4 p\"kick*4\"", txt)                # @d1..3 pris par le buffer de démarrage
        @test strip(ed.lines[ed.cursor_row] |> String) == "@d4 p\"kick*4\""
        @test haskey(Ressac._SYNTH_REGISTRY, :kick)             # enregistré → jouable
        @test occursin("ajouté", app.logs[end])
        # depuis DESIGN aussi (l'onglet courant : kick)
        _bex(app, "son")
        _bkey(app, 'U')
        @test _bws(app) == "PLAY"
        @test occursin("@d5 p\"kick*4\"", Tachikoma.text(Ressac._active_editor(app)))
    end
end

@testset "U depuis le son — sauve et pose un @dN dans les patterns ; Ctrl-w c ferme le volet" begin
    _in_sandbox() do
        app, tb, frame = _br_app()
        _bex(app, "synth zorglub")                             # starter une-ligne, dans le volet
        @test _bws(app) == "DESIGN" && Ressac._focused_role(app) === :synth
        Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w')); _bkey(app, 'c'); _bkey(app, :escape)
        Ressac._PANE_MODE.active = false
        @test app.volet === :fiche                             # Ctrl-w c ferme le volet
        _bex(app, "synth zorglub")                             # l'onglet zorglub redevient courant
        @test Ressac._focused_role(app) === :synth
        # depuis la DOC aussi, U envoie le son dans un pattern
        (_, sdoc) = Ressac._synth_workspace_parts(app)
        Ressac._focus_pane!(app, sdoc)
        _bkey(app, 'U')
        @test _bws(app) == "PLAY"
        @test occursin("p\"zorglub*4\"", Tachikoma.text(Ressac._active_editor(app)))
        @test isfile(joinpath(pwd(), "plugins", "user-synths", "zorglub.jl"))
    end
end

@testset "explorer — e (export) ouvre le candidat dans DESIGN" begin
    app, tb, frame = _br_app()
    _bex(app, "explore")
    p = Ressac._focused_pane_impl(app)
    @test p isa Ressac.SynthExplorerPane
    _bkey(app, 'e')                                            # nommage
    foreach(c -> _bkey(app, c), "cand"); _bkey(app, :enter)
    @test _bws(app) == "DESIGN"
    @test Ressac._focused_role(app) === :synth
    @test occursin("@synth", Tachikoma.text(Ressac._active_editor(app)))
    _bex(app, "explore")
    @test Ressac._focused_pane_impl(app) isa Ressac.SynthExplorerPane   # l'explorer est toujours là
end

# ── Étape 5 : zoom de pane, candidat ouvert à droite ────────────────────────────
@testset "zoom — Ctrl-w z rend la pane focalisée seule ; le focus ailleurs dézoome ; :zoom" begin
    app, tb, frame = _br_app()
    _bex(app, "vsplit log")
    ws = Ressac.current_workspace(app.workspaces)
    @test length(collect(Ressac._all_leaves(ws.tree))) == 2
    scr = _bscreen(app, tb, frame)
    @test occursin("JOURNAL", scr) && occursin("PATTERNS", scr)
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w')); _bkey(app, 'z'); _bkey(app, :escape)
    Ressac._PANE_MODE.active = false
    @test app.zoom_leaf == ws.focused_pane
    scr = _bscreen(app, tb, frame)
    @test occursin("JOURNAL", scr) && !occursin("─ PATTERNS", scr)   # seule la pane journal
    @test occursin("ZOOM", split(scr, "\n")[1])                     # badge dans la status line
    # rects : le leaf zoomé prend toute la largeur
    rects = Ressac._workspace_rects(app, ws, app._last_ws_area)
    @test length(rects) == 1 && first(values(rects)).w == 120
    # changement de focus → dézoom
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w')); _bkey(app, 'h'); _bkey(app, :escape)
    Ressac._PANE_MODE.active = false
    _bscreen(app, tb, frame)
    @test app.zoom_leaf == 0
    _bex(app, "zoom"); @test app.zoom_leaf != 0
    _bex(app, "zoom"); @test app.zoom_leaf == 0
end

@testset "M depuis l'explorateur — le candidat s'ouvre à droite, la DOC sur son explication ; :w le range" begin
    _in_sandbox() do
        try
            app, tb, frame = _br_app()
            _bex(app, "explore")
            _bkey(app, 'M')
            @test _bws(app) == "DESIGN" && app.volet === :son
            @test Ressac._focused_role(app) === :synth               # le clavier est dans le texte : c'est là qu'on travaille
            (ep, sdoc) = Ressac._synth_workspace_parts(app)
            @test ep.tabs[ep.current_tab].name == "candidat_1"
            @test occursin("@synth :candidat_1", Tachikoma.text(ep.tabs[ep.current_tab].code_editor))
            @test sdoc.mode === :explain && sdoc.genome !== nothing && !isempty(sdoc.explain_lines)
            scr = _bscreen(app, tb, frame)
            @test occursin("SYNTH · candidat_1", scr) && occursin("[explication]", scr)
            @test !occursin("STUDIO", scr)
            # M de nouveau sur le même candidat : le même onglet, pas un de plus
            ntabs = length(ep.tabs)
            _bex(app, "explore"); _bkey(app, 'M')
            @test length(Ressac._synth_workspace_parts(app)[1].tabs) == ntabs
            # :w <nom> range le son
            _bex(app, "w scusave")
            path = joinpath(pwd(), "plugins", "user-synths", "scusave.jl")
            @test isfile(path) && occursin("@synth :scusave", read(path, String))
            # ? donne l'aide du son
            _bkey(app, '?')
            @test app.modal === :help
            _bkey(app, :escape)
        finally
            Ressac._EXPLORER_EXPORT_REQUEST[] = nothing
        end
    end
end

# ── Régressions : layout restauré, onglet courant 0, défilement maintenu ──
@testset "layout — l'écran sauvé avec un son ouvert se restaure, et le volet s'échange encore" begin
    app, tb, frame = _br_app()
    _bex(app, "son")
    path = joinpath(mktempdir(), "layout.toml")
    Ressac.save_layout(app.workspaces, path)
    app2 = Ressac.RessacApp(; scheduler = Ressac.Scheduler(MockOSCClient(); cps = 0.5))
    Ressac.load_layout!(app2.workspaces, path)
    tb2 = Tachikoma.TestBackend(120, 40)
    frame2 = Tachikoma.Frame(tb2.buf, Tachikoma.Rect(1, 1, 120, 40), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app2, frame2)
    for leaf in Ressac._all_leaves(Ressac.current_workspace(app2.workspaces).tree)
        @test 1 <= leaf.current_tab <= length(leaf.tabs)
    end
    @test app2.volet === :son                                # reconnu à ce qu'il contient
    Ressac._active_editor(app2).mode = :normal
    _bex(app2, "back")
    @test app2.volet === :fiche && Ressac._focused_role(app2) === :patterns
    _bex(app2, "son")
    @test Ressac._focused_role(app2) === :synth
    @test (Tachikoma.view(app2, frame2); true)
    # un clic dans la pane, puis rendu : pas de BoundsError
    Tachikoma.update!(app2, Tachikoma.MouseEvent(60, 10, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
    @test (Tachikoma.view(app2, frame2); true)
end

@testset "layout — une disposition d'avant (trois workspaces) est reprise pour ce qu'elle contient" begin
    wm = Ressac.WorkspaceManager()
    for (name, role, text) in (("PLAY", "patterns", "@d1 p\"bd sn\""), ("DESIGN", "synth", "@synth :vieux (freq=110) saw(:freq)"))
        Ressac.create_workspace!(wm, name)
        ep = Ressac._pane_new(:editor, Dict{String,Any}("buffer_role" => role, "name" => role == "synth" ? "vieux" : "main"))
        Tachikoma.set_text!(ep.tabs[1].code_editor, text)
        leaf = wm.workspaces[end].tree
        push!(leaf.tabs, ep); leaf.current_tab = 1
    end
    Ressac.create_workspace!(wm, "EXPLORE")
    app = Ressac.RessacApp(; scheduler = Ressac.Scheduler(MockOSCClient(); cps = 0.5), workspaces = wm)
    Ressac._ensure_default_workspace!(app)
    @test length(app.workspaces.workspaces) == 1
    @test Tachikoma.text(Ressac._patterns_editor(app)) == "@d1 p\"bd sn\""
    Ressac._open_volet!(app, :son)
    @test occursin(":vieux", Tachikoma.text(Ressac._active_editor(app)))
end

@testset "garde — une pane sans onglet courant valide ne fait pas planter le rendu" begin
    app, tb, frame = _br_app()
    ws = Ressac.current_workspace(app.workspaces)
    leaf = Ressac._find_leaf_by_id(ws.tree, ws.focused_pane)
    leaf.current_tab = 0                              # état corrompu
    @test Ressac._focused_pane_impl(app) === nothing
    @test (Tachikoma.view(app, frame); true)
    leaf.current_tab = 1
end

@testset "défilement maintenu — key_repeat fait défiler le wiki, l'aide, le journal" begin
    app, tb, frame = _br_app()
    _bex(app, "wiki")
    @test app.modal === :none
    wp = Ressac._focused_pane_impl(app)
    @test wp isa Ressac.WikiPane                                # le wiki est une pane
    Tachikoma.view(app, frame)                                  # rendu : le ScrollPane reçoit son contenu
    Tachikoma.update!(app, Tachikoma.KeyEvent(:down, Tachikoma.key_repeat))
    Tachikoma.update!(app, Tachikoma.KeyEvent(:down, Tachikoma.key_repeat))
    @test wp.pane.offset == 2
    Tachikoma.update!(app, Tachikoma.KeyEvent(:char, 'k', Tachikoma.key_repeat))
    @test wp.pane.offset == 1
    _bex(app, "q")                                              # ferme la pane wiki
    _bkey(app, '?')
    Tachikoma.view(app, frame)                                  # l'aide rendue : son ScrollPane a son contenu
    Tachikoma.update!(app, Tachikoma.KeyEvent(:char, 'j', Tachikoma.key_repeat))
    @test app.modal_view.offset == 1
    _bkey(app, :escape)
    _bex(app, "vsplit log")
    p = Ressac._focused_pane_impl(app)
    for i in 1:60; Ressac._push_app_log!(app, "[INFO] ligne $i"); end
    Tachikoma.view(app, frame)
    Tachikoma.update!(app, Tachikoma.KeyEvent(:char, 'k', Tachikoma.key_repeat))
    @test p.pane.offset == Ressac._scroll_last(p.pane) - 1 && !p.pane.following
end

# ── :q ferme une pane, quitte sur la dernière ; Échap ×2 quitte ────────
@testset ":q — ferme la pane focalisée, quitte l'app sur la dernière ; :qa quitte" begin
    app, tb, frame = _br_app()
    _bex(app, "vsplit log")
    ws = Ressac.current_workspace(app.workspaces)
    @test length(collect(Ressac._all_leaves(ws.tree))) == 2
    _bex(app, "q")
    @test !app.quit
    @test length(collect(Ressac._all_leaves(ws.tree))) == 1
    _bex(app, "q")
    @test app.quit
    app2, _, _ = _br_app()
    _bex(app2, "vsplit log"); _bex(app2, "qa")
    @test app2.quit
end

@testset "Échap — une fois prévient, deux fois quitte ; rien avec plusieurs panes" begin
    app, tb, frame = _br_app()
    _bkey(app, :escape)
    @test !app.quit
    @test occursin("Échap encore", app.logs[end])
    _bkey(app, :escape)
    @test app.quit
    app2, _, _ = _br_app()
    _bex(app2, "vsplit log")                                  # depuis n'importe quelle pane
    _bkey(app2, :escape); _bkey(app2, :escape)
    @test app2.quit
    # en insertion, Échap reste « retour au mode normal »
    app3, _, _ = _br_app()
    _bkey(app3, 'i'); _bkey(app3, :escape)
    @test Ressac._active_editor(app3).mode === :normal && !app3.quit
end
