include(joinpath(@__DIR__, "helpers.jl"))
# Les trois modes compartimentés (palette, complétion, aide, pont des
# commandes), workspaces à neuf (:design! :reset), DESIGN remis en forme,
# Échap qui ne quitte pas, souris avec onglets, Space dans un son,
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
_mfws(app) = Dict(:play => "PLAY", :design => "DESIGN", :explore => "EXPLORE")[Ressac._workspace_mode(app)]
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

# Le texte principal : un pattern, puis le son `src` — le curseur sur sa
# première ligne, le clavier dans le texte.
function _mf_sound!(app, src::AbstractString)
    ed = Ressac._patterns_editor(app)
    Ressac._focus_patterns!(app)
    Tachikoma.set_text!(ed, "@d1 p\"bd\"\n\n" * src)
    ed.mode = :normal; ed.cursor_row = 3; ed.cursor_col = 0
    return ed
end
_mf_sound_text(app) = Ressac._sound_text(Ressac._current_sound(app))

@testset "contexte — les touches suivent le curseur, les commandes valent partout" begin
    app, tb, frame = _mf_app()
    @test Ressac._workspace_mode(app) === :play
    # Toute commande est proposée d'où qu'on soit : plus de tri par mode.
    verbs = Ressac._command_completion_candidates(app, "")
    @test "tap" in verbs && "mixer" in verbs && "prune" in verbs && "synth" in verbs && "todsl" in verbs
    @test !("play" in verbs) && !("design" in verbs)               # les trois écrans n'existent plus
    @test !("tabs" in verbs) && !("tabnext" in verbs)              # ni les onglets de sons
    # :synth écrit le son dans le texte, parmi les patterns ; la fiche reste à droite.
    _mfex(app, "synth zorg")
    @test app.volet === :fiche && Ressac._workspace_mode(app) === :design
    @test Ressac._focused_role(app) === :synth
    ed = Ressac._patterns_editor(app)
    @test ed === Ressac._active_editor(app)
    @test Ressac._current_sound(app).name == "zorg"
    @test _mf_sound_text(app) == "@synth :zorg (freq=220, sustain=0.5) sin_osc(:freq)"
    # l'aide complète montre les sections du contexte
    _mfkey(app, '?'); _mfkey(app, :tab)
    scopes = Ressac._help_scopes(app)
    @test :synth in scopes && :leader_synth in scopes && :synthdoc in scopes
    @test !(:patterns in scopes) && !(:tap in scopes) && !(:explorer in scopes)
    @test any(e -> occursin("tout SON", e[3]), Ressac._help_entries(app))
    _mfkey(app, :escape)
    # le curseur sort du bloc : ce sont les touches des patterns
    _mfkey(app, 'g'); _mfkey(app, 'g')
    @test Ressac._focused_role(app) === :patterns && Ressac._workspace_mode(app) === :play
    _mfkey(app, '?'); _mfkey(app, :tab)
    scopes = Ressac._help_scopes(app)
    @test :patterns in scopes && :leader in scopes && !(:synth in scopes)
    _mfkey(app, :escape)
end

@testset "écran — :reset le refait à neuf en gardant le texte ; un vieux layout est repris" begin
    oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]
    Ressac._WAVE_RENDER[] = _MF_STUB; Ressac._WAVE_SYNC[] = true
    try
        app, tb, frame = _mf_app()
        _mf_sound!(app, "@synth :sketch (freq=110) saw(:freq)")
        _mfex(app, "son")
        sdoc = Ressac._sound_doc(app)
        @test app.volet === :son && sdoc isa Ressac.SynthDocPane        # la DOC seule : pas de texte à droite
        @test Ressac._focused_pane_impl(app) === sdoc
        # Une pane scindée à côté par le joueur survit aux changements de volet.
        _mfex(app, "back")
        _mfex(app, "vsplit log")
        n_before = length(Ressac._all_leaves(Ressac.current_workspace(app.workspaces).tree))
        _mfex(app, "wiki"); _mfex(app, "back")
        leaves = Ressac._all_leaves(Ressac.current_workspace(app.workspaces).tree)
        @test length(leaves) == n_before
        @test any(l -> any(t -> t isa Ressac.LogPane, l.tabs), leaves)
        # Le son, lui, n'a pas bougé : il est dans le texte ; la DOC rouverte est la même.
        _mfex(app, "son")
        @test Ressac._sound_doc(app) === sdoc
        @test _mf_sound_text(app) == "@synth :sketch (freq=110) saw(:freq)"
        # :reset — l'écran à neuf autour du texte, sons compris.
        Ressac._edit_text!(Ressac._patterns_editor(app), "@d1 p\"à garder\"\n\n@synth :sketch (freq=110) saw(:freq)")
        _mfex(app, "reset")
        leaves = Ressac._all_leaves(Ressac.current_workspace(app.workspaces).tree)
        @test length(leaves) == 2 && app.volet === :fiche
        @test Tachikoma.text(Ressac._patterns_editor(app)) == "@d1 p\"à garder\"\n\n@synth :sketch (freq=110) saw(:freq)"
        @test Ressac._sound_doc(app) === nothing
        # un ancien layout à deux workspaces, dont une pane d'édition de son :
        # chargé, il donne l'écran unique autour du texte des patterns
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
        @test length(app2.workspaces.workspaces) == 1 && app2.volet === :fiche
        @test Tachikoma.text(Ressac._patterns_editor(app2)) == "@d1 \"bd\""
        buffers = [b for l in Ressac._all_leaves(Ressac.current_workspace(app2.workspaces).tree)
                     for t in l.tabs if t isa Ressac.EditorPane for b in t.tabs]
        @test length(buffers) == 1 && buffers[1].role === :patterns      # plus de pane d'édition de son
        _mfex(app2, "son")
        @test app2.volet === :son && Ressac._sound_doc(app2) !== nothing
    finally
        Ressac._WAVE_RENDER[] = oldr; Ressac._WAVE_SYNC[] = olds
    end
end

@testset "Échap ne quitte jamais Ressac, depuis n'importe quelle pane" begin
    oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]
    Ressac._WAVE_RENDER[] = _MF_STUB; Ressac._WAVE_SYNC[] = true
    try
        app, tb, frame = _mf_app()
        _mfex(app, "son")
        sdoc = Ressac._sound_doc(app)
        Ressac._focus_pane!(app, sdoc)                         # pas un éditeur
        @test Ressac._focused_pane_impl(app) === sdoc
        for _ in 1:3; _mfkey(app, :escape); end
        @test !app.quit
    finally
        Ressac._WAVE_RENDER[] = oldr; Ressac._WAVE_SYNC[] = olds
    end
end

@testset "souris — sous une bande d'onglets, le clic tombe sur la bonne ligne" begin
    app, tb, frame = _mf_app()
    ws = Ressac.current_workspace(app.workspaces)
    ep = only(t for t in Ressac._patterns_leaf(ws).tabs if t isa Ressac.EditorPane)
    push!(ep.tabs, Ressac.EditorBuffer(role = :patterns, name = "deux"))
    ep.current_tab = 2
    ed = ep.tabs[2].code_editor
    @test Ressac._active_editor(app) === ed
    Tachikoma.set_text!(ed, join(("ligne $i" for i in 1:15), "\n")); ed.mode = :normal
    _mfscreen(app, tb, frame)
    rect = Ressac._focused_editor_rect(app)
    leaf_rect = Ressac._workspace_rects(app, ws, app._last_ws_area)[ws.focused_pane]
    @test rect.y == leaf_rect.y + 2                          # bordure + bande d'onglets
    # la 11e ligne est rendue à rect.y + 10 : un clic là pose le curseur ligne 11
    y = rect.y + 10
    @test occursin("ligne 11", Tachikoma.row_text(tb, y))
    Tachikoma.update!(app, Tachikoma.MouseEvent(rect.x + 8, y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
    @test ed.cursor_row == 11
end

@testset "Space dans un son — les maillons du DSL" begin
    oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]
    Ressac._WAVE_RENDER[] = _MF_STUB; Ressac._WAVE_SYNC[] = true
    try
        app, tb, frame = _mf_app()
        ed = _mf_sound!(app, "@synth :sketch (freq=220) saw(:freq)")
        _mfkey(app, ' ')
        @test app.pending_leader
        scr = _mfscreen(app, tb, frame)
        @test occursin("passe-bas", scr) || occursin("saturation", scr)   # which-key du son
        _mfkey(app, 't')
        @test occursin("|> tanh_drive(", _mf_sound_text(app))
        @test startswith(Tachikoma.text(ed), "@d1 p\"bd\"\n\n@synth :sketch")    # le pattern n'a pas bougé
        @test !app.pending_leader
        # hors du bloc, Espace est le leader des patterns
        ed.cursor_row = 1
        _mfkey(app, ' ')
        @test Ressac._visible_layers(app) == ([(:leader, app)], "Space")
        _mfkey(app, :escape)
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
    # dans le texte : un .scd de la réserve est converti quand on l'amène (:synth), u l'enlève
    oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]
    Ressac._WAVE_RENDER[] = _MF_STUB; Ressac._WAVE_SYNC[] = true
    scd = joinpath(mkpath(joinpath(pwd(), "plugins", "user-synths")), "rezzbass.scd")
    try
        app, tb, frame = _mf_app()
        write(scd, src)
        before = Tachikoma.text(Ressac._patterns_editor(app))
        _mfex(app, "synth rezzbass")
        snd = Ressac._current_sound(app)
        @test snd !== nothing && snd.name == "rezzbass"
        @test occursin("@synth :rezzbass", Ressac._sound_text(snd)) && occursin("rlpf(", Ressac._sound_text(snd))
        @test !occursin("SynthDef(", Tachikoma.text(snd.code_editor))
        @test any(l -> occursin("converti depuis rezzbass.scd", l), app.logs)
        _mfkey(app, 'X')
        _mfscreen(app, tb, frame)
        @test Ressac._sound_doc(app).genome !== nothing          # la DOC suit
        _mfkey(app, 'u')
        @test Tachikoma.text(Ressac._patterns_editor(app)) == before
        # :todsl ne réécrit plus rien : il dit comment un .scd se convertit
        logs_before = length(app.logs)
        _mfex(app, "todsl")
        @test Tachikoma.text(Ressac._patterns_editor(app)) == before
        @test any(l -> occursin(":todsl", l) && occursin(":synth <nom>", l), app.logs[logs_before+1:end])
    finally
        rm(scd; force = true)
        delete!(Ressac._SYNTH_REGISTRY, :rezzbass)
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
        ed = _mf_sound!(app, "@synth :sketch (freq=220, sustain=0.5) saw(:freq) |> rlpf(800, 0.3)")
        _mfkey(app, 'K')                                        # la DOC s'ouvre à droite, le clavier reste dans le texte
        sdoc = Ressac._sound_doc(app)
        @test sdoc !== nothing && Ressac._active_editor(app) === ed && Ressac._focused_role(app) === :synth
        _mfscreen(app, tb, frame)
        # depuis la DOC : Espace ouvre le leader DSL et le maillon va dans le texte
        Ressac._focus_pane!(app, sdoc)
        _mfkey(app, ' ')
        @test app.pending_leader
        @test Ressac._visible_layers(app) == ([(:leader_synth, app)], "Space")
        _mfkey(app, 't')
        @test occursin("|> tanh_drive(", _mf_sound_text(app))
        @test Ressac._focused_pane_impl(app) === sdoc
        # T entend le son, D tient le drone, D relâche — depuis la DOC
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
        # les patterns : e évalue, m mute, depuis le wiki ouvert à côté
        _mfex(app, "wiki")
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
