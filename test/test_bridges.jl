# Ponts son ⟷ patterns : workspaces PLAY / DESIGN / EXPLORE, gs, U,
# :synth <nom> depuis la librairie, :sculpt robuste, export explorer.
using Test
using Ressac
import Tachikoma

if !isdefined(Main, :MockOSCClient)
    mutable struct MockOSCClient
        sent::Vector{Vector{UInt8}}
    end
    MockOSCClient() = MockOSCClient(Vector{UInt8}[])
    Ressac.send_osc(c::MockOSCClient, bytes::Vector{UInt8}) = push!(c.sent, bytes)
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
_bws(app) = Ressac.current_workspace(app.workspaces).name
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

@testset "workspaces — PLAY / DESIGN / EXPLORE au démarrage, remplis à la demande" begin
    app, tb, frame = _br_app()
    names = [w.name for w in app.workspaces.workspaces]
    @test names == ["PLAY", "DESIGN", "EXPLORE"]
    @test _bws(app) == "PLAY"
    @test Ressac._focused_role(app) === :patterns
    scr = _bscreen(app, tb, frame)
    @test occursin("1 PLAY", scr) && occursin("2 DESIGN", scr) && occursin("3 EXPLORE", scr)
    _bex(app, "design")
    @test _bws(app) == "DESIGN"
    @test Ressac._focused_role(app) === :synth               # sketch synth pré-rempli
    @test occursin("@synth :sketch", Tachikoma.text(Ressac._active_editor(app)))
    _bex(app, "explore")
    @test _bws(app) == "EXPLORE"
    @test Ressac._focused_pane_impl(app) isa Ressac.SynthExplorerPane
    @test occursin("EXPLORER", _bscreen(app, tb, frame))
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, '1'))
    @test _bws(app) == "PLAY"
    _bex(app, "play"); @test _bws(app) == "PLAY"
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
        _bex(app, "play")
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
        @test _bws(app) == "PLAY"                              # :synth ouvre dans le workspace courant
        _bkey(app, 'U')
        @test _bws(app) == "PLAY"
        @test Ressac._focused_role(app) === :patterns
        ed = Ressac._active_editor(app)
        txt = Tachikoma.text(ed)
        @test occursin("@d4 p\"kick*4\"", txt)                # @d1..3 pris par le buffer de démarrage
        @test strip(ed.lines[ed.cursor_row] |> String) == "@d4 p\"kick*4\""
        @test haskey(Ressac._SYNTH_REGISTRY, :kick)             # enregistré → jouable
        @test occursin("ajouté", app.logs[end])
        # depuis DESIGN aussi (sketch)
        _bex(app, "design")
        _bkey(app, 'U')
        @test _bws(app) == "PLAY"
        @test occursin("@d5 p\"sketch*4\"", Tachikoma.text(Ressac._active_editor(app)))
    end
end

@testset ":sculpt — accepte la forme une-ligne ; refuse un synth SC brut avec un message clair" begin
    _in_sandbox() do
        app, tb, frame = _br_app()
        _bex(app, "synth zorglub")                             # starter une-ligne
        _bex(app, "sculpt")
        @test Ressac._focused_sculpt_pane(app) !== nothing        # pane sculpt ouverte…
        @test app.zoom_leaf == Ressac.current_workspace(app.workspaces).focused_pane   # …et zoomée
        Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'w')); _bkey(app, 'c'); _bkey(app, :escape)
        Ressac._PANE_MODE.active = false
        @test Ressac._focused_sculpt_pane(app) === nothing         # Ctrl-w c ferme la pane
        write(joinpath(pwd(), "plugins", "user-synths", "raw.jl"),
              "@synth :raw (freq=220, sustain=0.5) SynthDSL.Sig(\"{ SinOsc.ar(freq) }.value\")\n")
        _bex(app, "sculpt raw")
        @test Ressac._focused_sculpt_pane(app) === nothing
        @test occursin("SC brut", app.logs[end])
        _bex(app, "sculpt nexistepas")
        @test occursin("introuvable", app.logs[end])
        # U depuis le studio sculpt (buffer focalisé = zorglub) : sauve + @dN dans PLAY
        Ressac._focused_role(app) === :synth || _bkey(app, :tab)   # refocalise la pane synth
        @test Ressac._focused_role(app) === :synth
        _bex(app, "sculpt")
        sp = Ressac._focused_sculpt_pane(app)
        @test sp !== nothing && sp.label == "zorglub"
        _bkey(app, 'U')
        @test _bws(app) == "PLAY"
        @test occursin("p\"zorglub*4\"", Tachikoma.text(Ressac._active_editor(app)))
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

# ── Étape 5 : zoom de pane, sculpt en pane ────────────────────────────
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

@testset "sculpt en pane — studio (onde, knobs groupés, explication), M depuis l'explorer, :w" begin
    _in_sandbox() do
        old = Ressac._WAVE_RENDER[]
        Ressac._WAVE_RENDER[] = (g -> (Float32[0.0f0, 0.1f0, 0.0f0], 44100))
        try
            app, tb, frame = _br_app()
            _bex(app, "explore")
            _bkey(app, 'M')                                   # sculpter le candidat focalisé
            sp = Ressac._focused_sculpt_pane(app)
            @test sp !== nothing && sp.sculpt
            @test app.zoom_leaf != 0
            @test !isempty(sp.explain_lines)
            scr = _bscreen(app, tb, frame)
            @test occursin("SCULPT · candidat", scr)
            @test occursin("▸ global", scr) || occursin("▸ ", scr)   # knobs groupés
            @test occursin("SYNTHÈSE", scr) || occursin("EN SORTIE", scr) || occursin("À LA BASE", scr)
            @test occursin("SCULPT", split(scr, "\n")[1])          # surface dans la status line
            # les touches vont bien à la pane
            f0 = sp.focus
            _bkey(app, 'j')
            @test sp.focus == f0 + 1
            # </> défile l'explication
            _bkey(app, '>'); @test sp.explain_scroll == 1
            _bkey(app, '<'); @test sp.explain_scroll == 0
            # :w <nom> sauve le sculpt (fichier avec génome embarqué)
            _bex(app, "w scusave")
            path = joinpath(pwd(), "plugins", "user-synths", "scusave.jl")
            @test isfile(path) && occursin("ressac-genome:", read(path, String))
            @test Ressac._focused_sculpt_pane(app) !== nothing    # on reste dans le studio
            # ? donne l'aide du sculpt
            _bkey(app, '?')
            @test app.modal === :help && app.help_scopes[1] === :sculpt
            _bkey(app, :escape)
            # e exporte dans DESIGN
            _bkey(app, 'e')
            @test _bws(app) == "DESIGN" && Ressac._focused_role(app) === :synth
        finally
            Ressac._WAVE_RENDER[] = old
            Ressac._EXPLORER_EXPORT_REQUEST[] = nothing
        end
    end
end

# ── Régressions : layout restauré, onglet courant 0, défilement maintenu ──
@testset "layout — un workspace vide sauvé/restauré reste vide, jamais de pane sans onglet courant" begin
    app, tb, frame = _br_app()                        # PLAY rempli, DESIGN/EXPLORE vides
    path = joinpath(mktempdir(), "layout.toml")
    Ressac.save_layout(app.workspaces, path)          # DESIGN/EXPLORE : current_tab 0
    wm = Ressac.WorkspaceManager()
    Ressac.load_layout!(wm, path)
    for ws in wm.workspaces
        for leaf in Ressac._all_leaves(ws.tree)
            @test isempty(leaf.tabs) || 1 <= leaf.current_tab <= length(leaf.tabs)
        end
    end
    design = wm.workspaces[findfirst(w -> w.name == "DESIGN", wm.workspaces)]
    @test design.tree isa Ressac.PaneLeaf && isempty(design.tree.tabs)
    # l'app relancée sur ce layout : DESIGN se remplit à la visite, aucun crash au rendu
    app2 = Ressac.RessacApp(; scheduler = Ressac.Scheduler(MockOSCClient(); cps = 0.5))
    Ressac.load_layout!(app2.workspaces, path)
    tb2 = Tachikoma.TestBackend(120, 40)
    frame2 = Tachikoma.Frame(tb2.buf, Tachikoma.Rect(1, 1, 120, 40), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app2, frame2)
    Ressac._active_editor(app2).mode = :normal
    _bex(app2, "design")
    @test Ressac._focused_role(app2) === :synth
    @test (Tachikoma.view(app2, frame2); true)
    # un clic dans la pane, puis rendu : pas de BoundsError
    Tachikoma.update!(app2, Tachikoma.MouseEvent(60, 10, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
    @test (Tachikoma.view(app2, frame2); true)
end

@testset "layout — un ancien layout sans noms reçoit PLAY/DESIGN/EXPLORE" begin
    wm = Ressac.WorkspaceManager()
    Ressac.create_workspace!(wm, "")
    app = Ressac.RessacApp(; scheduler = Ressac.Scheduler(MockOSCClient(); cps = 0.5), workspaces = wm)
    Ressac._ensure_default_workspace!(app)
    @test [w.name for w in app.workspaces.workspaces] == ["PLAY", "DESIGN", "EXPLORE"]
    @test app.workspaces.current_idx == 1
end

@testset "garde — une pane sans onglet courant valide ne fait pas planter le rendu" begin
    app, tb, frame = _br_app()
    ws = Ressac.current_workspace(app.workspaces)
    leaf = Ressac._find_leaf_by_id(ws.tree, ws.focused_pane)
    leaf.current_tab = 0                              # état corrompu
    @test Ressac._focused_pane_impl(app) === nothing
    @test !Ressac._is_waveform_sculpt_focused(app)
    @test (Tachikoma.view(app, frame); true)
    leaf.current_tab = 1
end

@testset "défilement maintenu — key_repeat fait défiler le wiki, l'aide, le journal" begin
    app, tb, frame = _br_app()
    _bex(app, "wiki")
    @test app.modal === :none
    wp = Ressac._focused_pane_impl(app)
    @test wp isa Ressac.WikiPane                                # le wiki est une pane
    Tachikoma.update!(app, Tachikoma.KeyEvent(:down, Tachikoma.key_repeat))
    Tachikoma.update!(app, Tachikoma.KeyEvent(:down, Tachikoma.key_repeat))
    @test wp.scroll == 2
    Tachikoma.update!(app, Tachikoma.KeyEvent(:char, 'k', Tachikoma.key_repeat))
    @test wp.scroll == 1
    _bex(app, "q")                                              # ferme la pane wiki
    _bkey(app, '?')
    Tachikoma.update!(app, Tachikoma.KeyEvent(:char, 'j', Tachikoma.key_repeat))
    @test app.modal_scroll == 1
    _bkey(app, :escape)
    _bex(app, "vsplit log")
    p = Ressac._focused_pane_impl(app)
    Tachikoma.update!(app, Tachikoma.KeyEvent(:char, 'k', Tachikoma.key_repeat))
    @test p.scroll == 1
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
    _bex(app2, "vsplit log")
    _bkey(app2, :escape); _bkey(app2, :escape)
    @test !app2.quit
    # en insertion, Échap reste « retour au mode normal »
    app3, _, _ = _br_app()
    _bkey(app3, 'i'); _bkey(app3, :escape)
    @test Ressac._active_editor(app3).mode === :normal && !app3.quit
end
