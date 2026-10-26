# Les trois modes compartimentés (palette, complétion, aide, pont des
# commandes), workspaces à neuf (:design! :reset), DESIGN remis en forme,
# Échap deux fois partout, souris avec onglets, Space dans le synth,
# :todsl, chargement des .jl avec |> en tête de ligne.
using Test
using Ressac
using Tachikoma

if !@isdefined(_MFMock)
    mutable struct _MFMock
        sent::Vector{Vector{UInt8}}
    end
    _MFMock() = _MFMock(Vector{UInt8}[])
    Ressac.send_osc(c::_MFMock, bytes::Vector{UInt8}) = push!(c.sent, bytes)
end

function _mf_app()
    app = Ressac.RessacApp(; scheduler = Ressac.Scheduler(_MFMock(); cps = 0.5))
    tb = Tachikoma.TestBackend(160, 44)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 160, 44),
                            Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    Ressac._PANE_MODE.active = false
    return app, tb, frame
end
_mfkey(app, c::Char) = Tachikoma.update!(app, Tachikoma.KeyEvent(c))
_mfkey(app, s::Symbol) = Tachikoma.update!(app, Tachikoma.KeyEvent(s))
_mfex(app, cmd) = (_mfkey(app, ':'); foreach(c -> _mfkey(app, c), cmd); _mfkey(app, :enter))
function _mfscreen(app, tb, frame)
    Tachikoma.reset!(tb.buf); Tachikoma.view(app, frame)
    join((Tachikoma.row_text(tb, y) for y in 1:44), "\n")
end
_mfws(app) = Ressac.current_workspace(app.workspaces).name
const _MF_STUB = g -> (Float32[0.0f0, 0.1f0, 0.0f0], 44100)

@testset "chargement — un .jl avec |> en tête de ligne se charge comme un plugin" begin
    path = joinpath(@__DIR__, "fixtures", "synths", "brin.jl")
    old = Ressac._LIVE_SCHEDULER[]
    Ressac._LIVE_SCHEDULER[] = nothing
    try
        @test_throws Exception Base.include(Ressac.SynthDSL, path)      # le parseur de Julia seul refuse
        src = Ressac.SynthDSL._dsl_preprocess(read(path, String))
        @test Base.include_string(Ressac.SynthDSL, src, path) isa String  # ce que fait le chargeur
    finally
        Ressac._LIVE_SCHEDULER[] = old
        delete!(Ressac._SYNTH_REGISTRY, :brin)
    end
end

@testset "modes — palette, complétion, aide et pont des commandes" begin
    app, tb, frame = _mf_app()
    @test Ressac._workspace_mode(app) === :play
    verbs = Ressac._ex_verbs_for_mode(app)
    @test "tap" in verbs && "mixer" in verbs && "play" in verbs
    @test !("sculpt" in verbs) && !("synth" in verbs) && !("todsl" in verbs)
    # le pont : :synth depuis PLAY ouvre DESIGN
    _mfex(app, "synth zorg")
    @test _mfws(app) == "DESIGN" && Ressac._workspace_mode(app) === :design
    @test any(l -> occursin(":synth vit dans DESIGN", l), app.logs)
    @test Ressac._focused_role(app) === :synth
    verbs = Ressac._ex_verbs_for_mode(app)
    @test "sculpt" in verbs && "todsl" in verbs && !("tap" in verbs)
    # l'aide complète ne montre que les sections du mode
    _mfkey(app, '?'); _mfkey(app, :tab)
    scopes = Ressac._help_scopes(app)
    @test :synth in scopes && :leader_synth in scopes && :sculpt in scopes
    @test !(:patterns in scopes) && !(:tap in scopes) && !(:explorer in scopes)
    @test any(e -> occursin("tout DESIGN", e[3]), Ressac._help_entries(app))
    _mfkey(app, :escape)
    _mfex(app, "play")
    _mfkey(app, '?'); _mfkey(app, :tab)
    scopes = Ressac._help_scopes(app)
    @test :patterns in scopes && :leader in scopes && !(:synth in scopes)
    _mfkey(app, :escape)
    # un mode sur deux : pas de pont (:sculpt existe aussi dans EXPLORE… non, :drone dans PLAY)
    @test !Ressac._mode_bridge!(app, "wiki")
end

@testset "workspaces — :design! / :reset à neuf, DESIGN remis en forme" begin
    oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]
    Ressac._WAVE_RENDER[] = _MF_STUB; Ressac._WAVE_SYNC[] = true
    try
        app, tb, frame = _mf_app()
        _mfex(app, "design")
        @test Ressac._synth_workspace_parts(app) !== nothing
        # on ferme le studio et la doc : :design remet la forme en gardant le texte
        ws = Ressac.current_workspace(app.workspaces)
        (ep, studio, sdoc) = Ressac._synth_workspace_parts(app)
        Tachikoma.set_text!(ep.tabs[1].code_editor, "@synth :sketch (freq=110) saw(:freq)\n")
        Ressac._focus_pane!(app, studio); Ressac.cmd_close!(app.workspaces)
        Ressac._focus_pane!(app, sdoc); Ressac.cmd_close!(app.workspaces)
        @test Ressac._synth_workspace_parts(app) === nothing
        _mfex(app, "play"); _mfex(app, "design")
        @test Ressac._synth_workspace_parts(app) !== nothing
        @test occursin("freq=110", Tachikoma.text(Ressac._synth_workspace_parts(app)[1].tabs[1].code_editor))
        @test any(l -> occursin("DESIGN remis en forme", l), app.logs)
        # :design! repart de zéro (le texte est perdu, le sketch revient)
        _mfex(app, "design!")
        @test length(Ressac._all_leaves(Ressac.current_workspace(app.workspaces).tree)) == 3
        @test occursin("@synth :sketch (freq=220", Tachikoma.text(Ressac._synth_workspace_parts(app)[1].tabs[1].code_editor))
        # :reset dans PLAY : patterns + wiki + doc
        _mfex(app, "play")
        _mfex(app, "vsplit log")
        @test length(Ressac._all_leaves(Ressac.current_workspace(app.workspaces).tree)) == 4
        _mfex(app, "reset")
        leaves = Ressac._all_leaves(Ressac.current_workspace(app.workspaces).tree)
        @test length(leaves) == 3
        @test any(t -> t isa Ressac.WikiPane, [t for l in leaves for t in l.tabs])
        # un ancien layout DESIGN (une seule pane) : chargé, visité, il prend la forme
        path = joinpath(mktempdir(), "layout.toml")
        write(path, """
        current_idx = 1
        [workspaces.0]
        name = "PLAY"
        focused_pane = 1
            [workspaces.0.tree]
            current_tab = 1
            kind = "editor"
            id = 1
            type = "pane"
                [workspaces.0.tree.state]
                current_tab = 1
                [[workspaces.0.tree.state.tabs]]
                role = "patterns"
                name = "main"
                content = "@d1 \\"bd\\""
        [workspaces.1]
        name = "DESIGN"
        focused_pane = 2
            [workspaces.1.tree]
            current_tab = 1
            kind = "editor"
            id = 2
            type = "pane"
                [workspaces.1.tree.state]
                current_tab = 1
                [[workspaces.1.tree.state.tabs]]
                role = "synth"
                name = "old"
                content = "@synth :old (freq=220) saw(:freq)"
        """)
        app2 = Ressac.RessacApp(; scheduler = Ressac.Scheduler(_MFMock(); cps = 0.5))
        Ressac.load_layout!(app2.workspaces, path)
        Ressac._ensure_default_workspace!(app2)
        tb2 = Tachikoma.TestBackend(160, 44)
        fr2 = Tachikoma.Frame(tb2.buf, Tachikoma.Rect(1, 1, 160, 44), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
        Tachikoma.view(app2, fr2)
        _mfex(app2, "design")
        parts = Ressac._synth_workspace_parts(app2)
        @test parts !== nothing && parts[1].tabs[1].name == "old"
    finally
        Ressac._WAVE_RENDER[] = oldr; Ressac._WAVE_SYNC[] = olds
    end
end

@testset "Échap deux fois quitte, depuis n'importe quelle pane" begin
    oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]
    Ressac._WAVE_RENDER[] = _MF_STUB; Ressac._WAVE_SYNC[] = true
    try
        app, tb, frame = _mf_app()
        _mfex(app, "design")
        (_, studio, _) = Ressac._synth_workspace_parts(app)
        Ressac._focus_pane!(app, studio)                       # pas un éditeur, trois panes
        app.esc_quit_at = 0.0
        _mfkey(app, :escape)
        @test !app.quit && occursin("Échap encore pour quitter", app.logs[end])
        _mfkey(app, :escape)
        @test app.quit
    finally
        Ressac._WAVE_RENDER[] = oldr; Ressac._WAVE_SYNC[] = olds
    end
end

@testset "souris — avec des onglets, le clic tombe sur la bonne ligne" begin
    oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]
    Ressac._WAVE_RENDER[] = _MF_STUB; Ressac._WAVE_SYNC[] = true
    try
        app, tb, frame = _mf_app()
        _mfex(app, "design"); _mfex(app, "synth deux")
        (ep, _, _) = Ressac._synth_workspace_parts(app)
        @test length(ep.tabs) == 2
        ed = ep.tabs[ep.current_tab].code_editor
        Tachikoma.set_text!(ed, join(("ligne $i" for i in 1:15), "\n")); ed.mode = :normal
        _mfscreen(app, tb, frame)
        rect = Ressac._focused_editor_rect(app)
        ws = Ressac.current_workspace(app.workspaces)
        leaf_rect = Ressac._workspace_rects(app, ws, app._last_ws_area)[ws.focused_pane]
        @test rect.y == leaf_rect.y + 2                          # bordure + bande d'onglets
        # la 11e ligne est rendue à rect.y + 10 : un clic là pose le curseur ligne 11
        y = rect.y + 10
        @test occursin("ligne 11", Tachikoma.row_text(tb, y))
        Tachikoma.update!(app, Tachikoma.MouseEvent(rect.x + 8, y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
        @test ed.cursor_row == 11
    finally
        Ressac._WAVE_RENDER[] = oldr; Ressac._WAVE_SYNC[] = olds
    end
end

@testset "Space dans le synth — les maillons du DSL" begin
    oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]
    Ressac._WAVE_RENDER[] = _MF_STUB; Ressac._WAVE_SYNC[] = true
    try
        app, tb, frame = _mf_app()
        _mfex(app, "design")
        (ep, _, _) = Ressac._synth_workspace_parts(app)
        ed = ep.tabs[1].code_editor
        Tachikoma.set_text!(ed, "@synth :sketch (freq=220) saw(:freq)\n"); ed.mode = :normal
        ed.cursor_row = 1
        _mfkey(app, ' ')
        @test app.pending_leader
        scr = _mfscreen(app, tb, frame)
        @test occursin("passe-bas", scr) || occursin("saturation", scr)   # which-key du synth
        _mfkey(app, 't')
        @test occursin("|> tanh_drive(", Tachikoma.text(ed))
        @test !app.pending_leader
    finally
        Ressac._WAVE_RENDER[] = oldr; Ressac._WAVE_SYNC[] = olds
    end
end

@testset ":todsl — un SynthDef écrit à la main devient du DSL" begin
    src = read(joinpath(@__DIR__, "fixtures", "synths", "rezzbass.scd"), String)
    parsed = Ressac.parse_synthdef(src)
    @test parsed !== nothing
    (name, args, expr) = parsed
    @test name === :rezzbass && args[:rate] == 4.0 && args[:depth] == 2000.0 && args[:freq] == 50.0
    @test occursin("Saw.ar(freq)", expr) && occursin("RLPF.ar", expr) && occursin("EnvGen.kr", expr)
    @test !occursin(r"\bosc\b", expr) && !occursin(r"\bfilt\b", expr)      # variables inlinées
    r = Ressac.synthdef_to_dsl(src)
    @test r !== nothing
    dsl = r[2]
    @test occursin("@synth :rezzbass (freq=50.0, sustain=1.0", dsl) && occursin("rate=4.0", dsl) && occursin("depth=2000.0", dsl)
    @test occursin("saw(:freq)", dsl) && occursin("rlpf(", dsl) && occursin("tanh_drive(", dsl) && occursin("env_linen(", dsl)
    g = Ressac.genome_from_dsl(dsl)
    @test g !== nothing
    # le texte compile en SynthDef, et c'est le même signal que le génome
    old = Ressac._LIVE_SCHEDULER[]; Ressac._LIVE_SCHEDULER[] = nothing
    try
        sc = Core.eval(Ressac.SynthDSL, Ressac.SynthDSL._dsl_parse_all(dsl))
        @test occursin("SynthDef(\\rezzbass", sc) && occursin("RLPF.ar", sc)
    finally
        Ressac._LIVE_SCHEDULER[] = old
        delete!(Ressac._SYNTH_REGISTRY, :rezzbass)
    end
    # dans l'éditeur : :todsl bascule le buffer, u annule
    oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]
    Ressac._WAVE_RENDER[] = _MF_STUB; Ressac._WAVE_SYNC[] = true
    try
        app, tb, frame = _mf_app()
        _mfex(app, "design")
        (ep, studio, _) = Ressac._synth_workspace_parts(app)
        tab = ep.tabs[1]
        tab.name = "rezzbass"; tab.synth_mode = :sc
        Tachikoma.set_text!(tab.code_editor, src); tab.code_editor.mode = :normal
        _mfex(app, "todsl")
        @test tab.synth_mode === :dsl
        @test occursin("@synth :rezzbass", Tachikoma.text(tab.code_editor))
        _mfscreen(app, tb, frame)
        @test studio.genome !== nothing                          # le studio suit
        _mfkey(app, 'u')
        @test occursin("SynthDef(\\rezzbass", Tachikoma.text(tab.code_editor))
    finally
        Ressac._WAVE_RENDER[] = oldr; Ressac._WAVE_SYNC[] = olds
    end
    @test Ressac.synthdef_to_dsl("pas un synthdef") === nothing
end

@testset "touches de mode — les mêmes gestes depuis n'importe quelle pane" begin
    oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]
    Ressac._WAVE_RENDER[] = _MF_STUB; Ressac._WAVE_SYNC[] = true
    old = Ressac._LIVE_SCHEDULER[]
    empty!(Ressac._DRONES)
    try
        app, tb, frame = _mf_app()
        Ressac._LIVE_SCHEDULER[] = app.scheduler
        _mfex(app, "design")
        (ep, studio, sdoc) = Ressac._synth_workspace_parts(app)
        ed = ep.tabs[1].code_editor
        Tachikoma.set_text!(ed, "@synth :sketch (freq=220, sustain=0.5) saw(:freq) |> rlpf(800, 0.3)\n"); ed.mode = :normal
        _mfscreen(app, tb, frame)
        # depuis le studio : Espace ouvre le leader DSL et le maillon va dans le texte
        Ressac._focus_pane!(app, studio)
        _mfkey(app, ' ')
        @test app.pending_leader
        @test Ressac._visible_layers(app) == ([(:leader_synth, app)], "Space")
        _mfkey(app, 't')
        @test occursin("|> tanh_drive(", Tachikoma.text(ed))
        @test Ressac._focused_pane_impl(app) === studio
        # T entend le son, D tient le drone, D relâche — depuis le studio
        n0 = length(app.scheduler.osc.sent)
        _mfkey(app, 'T')
        @test length(app.scheduler.osc.sent) > n0
        _mfkey(app, 'D')
        @test Ressac.drone_running(:sketch)
        # depuis la MODULATION : T réévalue, D relâche (plus de touches propres)
        Ressac._focus_pane!(app, Ressac._find_pane(app, Ressac.DronePane))
        _mfkey(app, 'T')
        @test Ressac.drone_running(:sketch)
        _mfkey(app, 'D')
        @test !Ressac.drone_running(:sketch)
        # depuis la DOC : X l'explication, Y le graphe, K la fiche
        Ressac._focus_pane!(app, sdoc)
        _mfkey(app, 'X'); @test sdoc.mode === :explain
        _mfkey(app, 'Y'); @test sdoc.mode === :graph
        _mfkey(app, 'K'); @test sdoc.mode === :doc
        # la barre de touches montre les gestes du mode avant ceux de la pane
        _mfscreen(app, tb, frame)
        bar = Ressac.hint_text(Ressac._keybar_layers(app)[1])
        @test startswith(bar, "T entendre · D drone")
        @test occursin("j défiler", bar)
        # PLAY : e évalue, m mute, depuis le wiki
        _mfex(app, "play")
        wiki = Ressac._find_pane(app, Ressac.WikiPane)
        Ressac._focus_pane!(app, wiki)
        ped = Ressac._active_editor(app)
        Tachikoma.set_text!(ped, "@d1 \"bd*4\"\n"); ped.mode = :normal; ped.cursor_row = 1
        _mfkey(app, 'm')
        @test startswith(String(ped.lines[1]), "#")
        _mfkey(app, 'm')
        @test !startswith(String(ped.lines[1]), "#")
        # EXPLORE : T entend le candidat depuis une pane voisine, B tune/brew sur l'explorateur
        _mfex(app, "explore")
        p = Ressac._focused_pane_impl(app)
        @test p isa Ressac.SynthExplorerPane
        n1 = length(app.scheduler.osc.sent)
        _mfkey(app, 'T')
        @test length(app.scheduler.osc.sent) > n1
        m0 = p.mode
        _mfkey(app, 'B')
        @test p.mode != m0
    finally
        Ressac._LIVE_SCHEDULER[] = old
        Ressac._WAVE_RENDER[] = oldr; Ressac._WAVE_SYNC[] = olds
        empty!(Ressac._DRONES)
    end
end
