include(joinpath(@__DIR__, "helpers.jl"))
# Ponts son ⟷ patterns : le mode suit le curseur (PLAY / DESIGN / EXPLORE),
# gs et :synth <nom> amènent un son dans le texte, U, export et M de l'explorateur.
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
# Le son sur lequel on travaille, et son texte.
_bsound(app) = Ressac._current_sound(app)
_bsound_text(app) = Ressac._sound_text(Ressac._current_sound(app))
_bwhole(app) = Tachikoma.text(Ressac._patterns_editor(app))
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
    patterns = _bwhole(app)
    # :son — la DOC d'un son, à droite ; elle n'écrit rien dans le texte.
    _bex(app, "son")
    @test _bws(app) == "DESIGN" && app.volet === :son
    @test Ressac._focused_pane_impl(app) isa Ressac.SynthDocPane
    @test Ressac._sound_doc(app) !== nothing && _bwhole(app) == patterns
    @test occursin("PATTERNS", _bscreen(app, tb, frame))     # les patterns restent à l'écran
    _bex(app, "explore")
    @test _bws(app) == "EXPLORE"
    @test Ressac._focused_pane_impl(app) isa Ressac.SynthExplorerPane
    @test occursin("EXPLORER", _bscreen(app, tb, frame))
    _bex(app, "back")
    @test _bws(app) == "PLAY" && app.volet === :fiche && app.zoom_leaf == 0
    @test _bwhole(app) == patterns
    # Le mode suit le curseur : dans un bloc @synth on travaille un son, ailleurs les patterns.
    ed = Ressac._patterns_editor(app)
    ed.cursor_row = findfirst(l -> startswith(String(l), "@d1"), ed.lines)
    Ressac._open_sound!(app, "essai")
    @test _bws(app) == "DESIGN" && Ressac._focused_role(app) === :synth && app.volet === :fiche
    @test _bsound(app).name == "essai" && _bsound_text(app) == "@synth :essai (freq=220, sustain=0.5) sin_osc(:freq)"
    @test occursin("SON · essai", _bscreen(app, tb, frame))
    row = ed.cursor_row
    ed.cursor_row = 1
    @test _bws(app) == "PLAY" && Ressac._focused_role(app) === :patterns && _bsound(app) === nothing
    @test !occursin("SON · essai", _bscreen(app, tb, frame))
    ed.cursor_row = row
    # Changer de volet ne touche pas au texte ; :close est :back.
    with_sound = _bwhole(app)
    _bex(app, "wiki"); @test app.volet === :wiki
    _bex(app, "son");  @test app.volet === :son
    _bex(app, "close"); @test app.volet === :fiche
    @test _bwhole(app) == with_sound && Ressac._focused_role(app) === :synth
    # :q ferme le volet, puis seulement quitte.
    _bex(app, "wiki")
    _bex(app, "q"); @test app.volet === :fiche && !app.quit
    @test Ressac._focused_buffer(app) !== nothing            # le clavier est revenu dans le texte
    @test _bwhole(app) == with_sound
end

@testset ":synth <nom> écrit la recette de librairie dans le texte (copie éditable), pas un starter vide" begin
    _in_sandbox() do
        app, tb, frame = _br_app()
        patterns = _bwhole(app)
        _bex(app, "synth kick")
        @test Ressac._focused_role(app) === :synth
        @test _bsound(app).name == "kick"
        txt = _bsound_text(app)
        @test occursin("env_perc", txt)                        # la recette, pas sin_osc(:freq) seul
        @test startswith(txt, "@synth :kick")
        @test !occursin("ressac-genome", _bwhole(app))         # la ligne du génome reste dans le fichier
        @test isfile(joinpath(pwd(), "plugins", "user-synths", "kick.jl"))
        for l in split(rstrip(patterns), '\n')                 # rien de ce qui était écrit n'est perdu
            @test occursin(l, _bwhole(app))
        end
        # un nom inconnu garde le starter ; il se pose sous le son du curseur
        _bex(app, "synth zorglub")
        @test _bsound_text(app) == "@synth :zorglub (freq=220, sustain=0.5) sin_osc(:freq)"
        ed = Ressac._patterns_editor(app)
        kick = Ressac._sound_block_named(ed.lines, "kick"); zorg = Ressac._sound_block_named(ed.lines, "zorglub")
        @test kick !== nothing && zorg.row == kick.last_row + 2 && isempty(strip(String(ed.lines[kick.last_row + 1])))
        # un son déjà dans le texte : on y va, sans le réécrire
        whole = _bwhole(app)
        _bex(app, "synth kick")
        @test _bwhole(app) == whole && ed.cursor_row == kick.row && _bsound(app).name == "kick"
        # :synth seul : un brouillon sketch_xxx
        _bex(app, "synth")
        @test occursin(r"^sketch_\w{3}$", _bsound(app).name) && occursin("sin_osc(:freq)", _bsound_text(app))
    end
end

@testset "gs — amène le synth sous le curseur dans le texte ; mot inconnu → message" begin
    _in_sandbox() do
        app, tb, frame = _br_app()
        ed = Ressac._active_editor(app)
        Tachikoma.set_text!(ed, "@d1 p\"kick*4\"\n@d2 p\"pasunson\"")
        ed.cursor_row = 1; ed.cursor_col = 8                  # sur « kick »
        _bkey(app, 'g'); _bkey(app, 's')
        @test _bws(app) == "DESIGN"
        @test Ressac._focused_role(app) === :synth
        @test _bsound(app).name == "kick"
        @test occursin("env_perc", _bsound_text(app))
        lines = [String(l) for l in ed.lines]
        k = findfirst(l -> startswith(l, "@synth :kick"), lines)
        @test lines[1:2] == ["@d1 p\"kick*4\"", ""] && ed.cursor_row == k      # sous le bloc du curseur, curseur sur le @synth
        @test all(l -> isempty(l) || startswith(l, "#"), lines[3:(k - 1)])    # l'en-tête de la recette vient avec
        @test lines[end] == "@d2 p\"pasunson\"" && isempty(strip(lines[end - 1]))
        # gs de nouveau sur le même nom : le même bloc, pas un de plus
        ed.cursor_row = 1; ed.cursor_col = 8
        _bkey(app, 'g'); _bkey(app, 's')
        @test ed.cursor_row == k && [String(l) for l in ed.lines] == lines
        # mot inconnu
        ed.cursor_row = length(ed.lines); ed.cursor_col = 8   # sur « pasunson »
        whole = _bwhole(app)
        _bkey(app, 'g'); _bkey(app, 's')
        @test _bws(app) == "PLAY" && _bwhole(app) == whole
        @test occursin("pas un synth connu", app.logs[end])
    end
end

@testset "U — dans un son : il est rangé, puis @dN p\"nom*4\" au bout du texte" begin
    _in_sandbox() do
        app, tb, frame = _br_app()
        _bex(app, "synth kick")
        @test _bws(app) == "DESIGN"                            # le curseur est dans le son
        _bkey(app, 'U')
        @test _bws(app) == "PLAY"
        @test Ressac._focused_role(app) === :patterns
        ed = Ressac._active_editor(app)
        txt = Tachikoma.text(ed)
        @test occursin("@d4 p\"kick*4\"", txt)                # @d1..3 pris par le buffer de démarrage
        @test strip(ed.lines[ed.cursor_row] |> String) == "@d4 p\"kick*4\""
        @test ed.cursor_row == findlast(l -> !isempty(strip(String(l))), ed.lines)   # au bout du texte
        @test haskey(Ressac._SYNTH_REGISTRY, :kick)             # enregistré → jouable
        @test occursin("ajouté", app.logs[end])
        # hors d'un son, U ne pose rien
        _bkey(app, 'U')
        @test Tachikoma.text(ed) == txt
        # de retour dans le son, U pose le slot suivant
        Ressac._open_sound!(app, "kick")
        _bkey(app, 'U')
        @test _bws(app) == "PLAY"
        @test occursin("@d5 p\"kick*4\"", Tachikoma.text(Ressac._active_editor(app)))
    end
end

@testset "U depuis la DOC du son — range le son et pose un @dN ; Ctrl-w c ferme le volet" begin
    _in_sandbox() do
        app, tb, frame = _br_app()
        _bex(app, "synth zorglub")                             # starter une-ligne, dans le texte
        @test _bws(app) == "DESIGN" && Ressac._focused_role(app) === :synth
        @test !isfile(joinpath(pwd(), "plugins", "user-synths", "zorglub.jl"))   # écrit dans le texte, pas encore rangé
        _bex(app, "son")
        sdoc = Ressac._sound_doc(app)
        @test app.volet === :son && Ressac._focused_pane_impl(app) === sdoc
        Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w')); _bkey(app, 'c'); _bkey(app, :escape)
        Ressac._PANE_MODE.active = false
        @test app.volet === :fiche                             # Ctrl-w c ferme le volet
        @test Ressac._focused_role(app) === :synth             # le clavier est revenu sur le son
        # depuis la DOC aussi, U envoie le son dans un pattern
        _bex(app, "son")
        @test Ressac._focused_pane_impl(app) === Ressac._sound_doc(app) && _bsound(app).name == "zorglub"
        _bkey(app, 'U')
        @test _bws(app) == "PLAY"
        @test occursin("p\"zorglub*4\"", Tachikoma.text(Ressac._active_editor(app)))
        @test occursin("@synth :zorglub", read(joinpath(pwd(), "plugins", "user-synths", "zorglub.jl"), String))
    end
end

@testset "explorer — e (export) écrit le candidat dans le texte principal" begin
    app, tb, frame = _br_app()
    _bex(app, "explore")
    p = Ressac._focused_pane_impl(app)
    @test p isa Ressac.SynthExplorerPane
    _bkey(app, 'e')                                            # nommage
    foreach(c -> _bkey(app, c), "cand"); _bkey(app, :enter)
    @test _bws(app) == "DESIGN" && Ressac._focused_role(app) === :synth   # le clavier est dans le texte, sur le son
    @test _bsound(app).name == "cand" && startswith(_bsound_text(app), "@synth :cand")
    @test !occursin("ressac-genome", _bwhole(app))
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

@testset "M depuis l'explorateur — le candidat s'écrit dans le texte principal ; :keep le range" begin
    _in_sandbox() do
        try
            app, tb, frame = _br_app()
            ed = Ressac._patterns_editor(app)
            Tachikoma.set_text!(ed, "@d1 p\"bd sn\"\n  |> gain(0.8)\n@d2 p\"hh*4\"")
            ed.cursor_row = 1
            _bex(app, "explore")
            _bkey(app, 'M')
            @test Ressac._focused_role(app) === :synth               # le clavier est dans le texte, sur le son
            @test _bws(app) == "DESIGN" && app.volet !== :son         # plus de volet pour le texte d'un son
            lines = [String(l) for l in ed.lines]
            @test lines[1:3] == ["@d1 p\"bd sn\"", "  |> gain(0.8)", ""]   # posé SOUS le bloc du curseur, pas dedans
            @test startswith(lines[4], "@synth :candidat_1") && ed.cursor_row == 4
            @test lines[end] == "@d2 p\"hh*4\"" && isempty(strip(lines[end - 1]))
            @test !occursin("ressac-genome", Tachikoma.text(ed))     # la ligne du génome n'encombre pas le texte
            @test Ressac.synth_info(:candidat_1) !== nothing         # défini : s("candidat_1") le joue
            hit = Ressac._sound_under_cursor(app)
            @test hit !== nothing && hit.name == "candidat_1" && Ressac._sound_rows(hit)[1] == 4
            # M de nouveau sur le même candidat : le même bloc, pas un de plus
            _bex(app, "explore"); _bkey(app, 'M')
            @test count(l -> startswith(String(l), "@synth :candidat_1"), ed.lines) == 1
            # :w <nom> écrit la session (le son avec) et dit que le son, lui, n'est pas dans la réserve
            dir = joinpath(pwd(), "plugins", "user-synths")
            _bex(app, "w brouillon")
            @test !isfile(joinpath(dir, "candidat_1.jl")) && !isfile(joinpath(dir, "brouillon.jl"))
            @test app.session_name == "brouillon" && read(Ressac._session_path("brouillon"), String) == Tachikoma.text(ed)
            @test occursin("candidat_1", app.logs[end]) && occursin(":save", app.logs[end])
            # :keep le range sous son nom ; :keep <nom> sous un autre, et le bloc prend ce nom
            _bex(app, "keep")
            @test occursin("@synth :candidat_1", read(joinpath(dir, "candidat_1.jl"), String))
            _bex(app, "keep scusave")
            @test occursin("@synth :scusave", read(joinpath(dir, "scusave.jl"), String))
            @test any(l -> startswith(String(l), "@synth :scusave"), ed.lines)
            @test Ressac.synth_info(:scusave) !== nothing
            _bex(app, "keep pas-un-nom")
            @test !isfile(joinpath(dir, "pas-un-nom.jl")) && occursin("n'est pas un nom de son", app.logs[end])
            # Espace W range aussi le son du curseur
            rm(joinpath(dir, "scusave.jl"))
            _bkey(app, ' '); _bkey(app, 'W')
            @test occursin("@synth :scusave", read(joinpath(dir, "scusave.jl"), String))
            # sur un @dN, :keep <nom> range toujours le pattern, pas un son
            ed.cursor_row = 1
            @test Ressac._sound_under_cursor(app) === nothing
            _bex(app, "keep monpat")
            @test !isfile(joinpath(dir, "monpat.jl"))
            @test Ressac.load_pattern("monpat").code == "@d1 p\"bd sn\" |> gain(0.8)"
            # K sur un mot du son : la fiche du langage des sons
            Tachikoma.set_text!(ed, "@synth :essai (freq=220) begin\n    saw(:freq)\n    |> rlpf(900, 0.3)\nend\n@d1 p\"bd\"")
            ed.cursor_row = 2; ed.cursor_col = 5
            @test Ressac._doc_target_under_cursor(app) == "dsl:saw"
            ed.cursor_row = 5; ed.cursor_col = 5
            @test !startswith(Ressac._doc_target_under_cursor(app), "dsl:")
            # :format ne touche que le bloc du son
            Tachikoma.set_text!(ed, "@d1 p\"bd\" |> gain(0.8) |> pan(0.2)\n\n@synth :essai (freq=220) saw(:freq) |> rlpf(900, 0.3) |> safe()")
            ed.cursor_row = 3
            _bex(app, "format")
            lines = [String(l) for l in ed.lines]
            @test lines[1] == "@d1 p\"bd\" |> gain(0.8) |> pan(0.2)"
            @test length(lines) > 3 && any(l -> startswith(lstrip(l), "|> rlpf"), lines)
        finally
            Ressac._EXPLORER_EXPORT_REQUEST[] = nothing
        end
    end
end

# ── Régressions : layout restauré, onglet courant 0, défilement maintenu ──
@testset "layout — l'écran sauvé avec la DOC d'un son se restaure, et le volet s'échange encore" begin
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
    @test Ressac._sound_doc(app2) !== nothing
    Ressac._active_editor(app2).mode = :normal
    _bex(app2, "back")
    @test app2.volet === :fiche && Ressac._focused_role(app2) === :patterns
    _bex(app2, "son")
    @test app2.volet === :son && Ressac._focused_pane_impl(app2) isa Ressac.SynthDocPane
    @test (Tachikoma.view(app2, frame2); true)
    # un clic dans la pane, puis rendu : pas de BoundsError
    Tachikoma.update!(app2, Tachikoma.MouseEvent(60, 10, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
    @test (Tachikoma.view(app2, frame2); true)
end

@testset "layout — une disposition d'avant (trois workspaces, un éditeur de son) est reprise pour son texte de patterns" begin
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
    # L'éditeur de son d'avant n'est pas repris : un seul texte, celui des patterns.
    editors = [t for l in Ressac._all_leaves(Ressac.current_workspace(app.workspaces).tree) for t in l.tabs if t isa Ressac.EditorPane]
    @test length(editors) == 1 && all(b -> b.role === :patterns, only(editors).tabs)
    @test app.volet === :fiche
    Ressac._open_volet!(app, :son)
    @test Ressac._focused_pane_impl(app) isa Ressac.SynthDocPane
end

# Un seul workspace, mais une pane d'édition de son à côté des patterns
# (l'écran unique d'avant « le son dans le texte ») : rebâti lui aussi.
@testset "layout — une pane d'édition de son à côté des patterns n'est pas restaurée" begin
    app, tb, frame = _br_app()
    ws = Ressac.current_workspace(app.workspaces)
    patterns = _bwhole(app)
    old = Ressac._pane_new(:editor, Dict{String,Any}("buffer_role" => "synth", "name" => "vieux"))
    Tachikoma.set_text!(old.tabs[1].code_editor, "@synth :vieux (freq=110) saw(:freq)")
    push!(Ressac._find_leaf_by_id(ws.tree, ws.focused_pane).tabs, old)
    Ressac._ensure_default_workspace!(app)
    editors = [t for l in Ressac._all_leaves(Ressac.current_workspace(app.workspaces).tree) for t in l.tabs if t isa Ressac.EditorPane]
    @test length(editors) == 1 && all(b -> b.role === :patterns, only(editors).tabs)
    @test _bwhole(app) == patterns && app.volet === :fiche
    @test (Tachikoma.view(app, frame); true)
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

@testset "Échap — ne quitte jamais (on quitte par :q / :qa)" begin
    app, tb, frame = _br_app()
    for _ in 1:3; _bkey(app, :escape); end
    @test !app.quit
    app2, _, _ = _br_app()
    _bex(app2, "vsplit log")                                  # depuis n'importe quelle pane
    _bkey(app2, :escape); _bkey(app2, :escape)
    @test !app2.quit
    # en insertion, Échap reste « retour au mode normal »
    app3, _, _ = _br_app()
    _bkey(app3, 'i'); _bkey(app3, :escape)
    @test Ressac._active_editor(app3).mode === :normal && !app3.quit
end
