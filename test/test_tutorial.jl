include(joinpath(@__DIR__, "helpers.jl"))
# Le tutoriel pas à pas : une pane qui suit ce que fait le joueur.
using Test
using Ressac
using Tachikoma

function _tu_app()
    app = Ressac.RessacApp(; scheduler = Ressac.Scheduler(MockOSCClient(); cps = 0.5))
    tb = Tachikoma.TestBackend(120, 40)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 120, 40), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    Ressac._PANE_MODE.active = false
    Ressac._active_editor(app).mode = :normal
    return app, tb, frame
end
_tk(app, k) = Tachikoma.update!(app, Tachikoma.KeyEvent(k))
_tex(app, cmd) = (_tk(app, ':'); foreach(c -> _tk(app, c), cmd); _tk(app, :enter))
_ttype(app, s) = foreach(c -> _tk(app, c), s)
_tscreen(app, tb, frame) = (Tachikoma.view(app, frame); join((Tachikoma.row_text(tb, y) for y in 1:40), "\n"))

@testset "tutoriel — la pane suit ce que fait le joueur" begin
    app, tb, frame = _tu_app()
    old = Ressac._LIVE_SCHEDULER[]; Ressac._LIVE_SCHEDULER[] = app.scheduler
    empty!(Ressac._APP_MUTED_PATTERNS)
    try
        _tex(app, "tutorial")
        p = Ressac._find_pane(app, Ressac.TutorialPane)
        @test p !== nothing && p.step == 1 && !p.finished
        @test Ressac._focused_pane_impl(app) isa Ressac.EditorPane          # le focus reste à l'éditeur
        scr = _tscreen(app, tb, frame)
        @test occursin("TUTORIEL · 1/", scr) && occursin("Deux modes", scr) && occursin("▶", scr)
        ed = Ressac._active_editor(app)
        # 1. i → insertion ; 2. Esc → normal
        _tk(app, 'i'); _tscreen(app, tb, frame); @test p.step == 2
        _tk(app, :escape); _tscreen(app, tb, frame); @test p.step == 3
        # 3. écrire un pattern (le buffer de départ en a déjà : il suffit d'être en normal)
        Tachikoma.set_text!(ed, ""); ed.cursor_row = 1; ed.cursor_col = 0
        _tscreen(app, tb, frame); @test p.step == 3                          # rien tant que pas de @dN
        _tk(app, 'i'); _ttype(app, "@d1 \"bd sn hh sn\""); _tk(app, :escape)
        _tscreen(app, tb, frame); @test p.step == 4
        # 4. jouer
        _tk(app, 'e'); _tscreen(app, tb, frame)
        @test haskey(app.scheduler.patterns, :d1) && p.step == 5
        @test haskey(p.snapshot, :d1)
        # 5. changer en jouant : réévaluer sans rien changer ne suffit pas, changer sans réévaluer non plus
        _tk(app, 'e'); _tscreen(app, tb, frame); @test p.step == 5
        Tachikoma.set_text!(ed, "@d1 \"bd*2 sn hh sn\""); ed.cursor_row = 1
        _tscreen(app, tb, frame); @test p.step == 5
        _tk(app, 'e'); _tscreen(app, tb, frame); @test p.step == 6
        # 6. couper, 7. remettre
        _tk(app, 'm'); _tscreen(app, tb, frame); @test p.step == 7
        _tk(app, 'm'); _tscreen(app, tb, frame); @test p.step == 8
        # 8. un contrôle
        Tachikoma.set_text!(ed, "@d1 \"bd sn hh sn\" |> gain(0.7)"); ed.cursor_row = 1
        _tk(app, 'e'); _tscreen(app, tb, frame); @test p.step == 9
        # 9. deuxième voix
        Tachikoma.set_text!(ed, "@d1 \"bd sn hh sn\" |> gain(0.7)\n@d2 \"~ cp\"")
        _tk(app, 'E'); _tscreen(app, tb, frame); @test length(app.scheduler.patterns) == 2 && p.step == 10
        # 10. tout arrêter
        _tk(app, ','); _tscreen(app, tb, frame); @test isempty(app.scheduler.patterns) && p.step == 11
        # 11. la palette, 12. l'aide
        Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'p')); _tscreen(app, tb, frame); @test p.step == 12
        _tk(app, :escape)
        _tk(app, '?'); _tscreen(app, tb, frame); @test p.step == 13
        _tk(app, :escape)
        @test occursin("Concevoir un son", _tscreen(app, tb, frame)) && !p.finished
        # ── chapitre DESIGN : le tutoriel suit le joueur ──
        oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]
        Ressac._WAVE_RENDER[] = g -> (Float32[0.0f0, 0.1f0, 0.0f0], 44100); Ressac._WAVE_SYNC[] = true
        dir = mktempdir(); mkpath(joinpath(dir, "plugins", "user-synths")); oldwd = pwd(); cd(dir)
        empty!(Ressac._DRONES)
        try
            _tex(app, "design"); _tscreen(app, tb, frame)
            @test Ressac.current_workspace(app.workspaces).name == "DESIGN"
            q = Ressac._find_pane(app, Ressac.TutorialPane)
            @test q !== nothing && q !== p && q.step == 14                   # une pane tutoriel s'est ouverte ici
            @test Ressac._focused_role(app) === :synth                       # le focus est resté au texte
            @test occursin("Trois panes", _tscreen(app, tb, frame))
            _tk(app, 'T'); _tscreen(app, tb, frame); @test q.step == 15
            (ep, studio, sdoc) = Ressac._synth_workspace_parts(app)
            ed = ep.tabs[ep.current_tab].code_editor
            Tachikoma.set_text!(ed, "@synth :sketch (freq=220, sustain=0.5) saw(:freq) |> rlpf(800, 0.3)\n"); ed.mode = :normal
            _tscreen(app, tb, frame); @test q.step == 16
            Ressac._focus_pane!(app, studio)
            _tscreen(app, tb, frame); @test q.step == 16                      # le studio focalisé ne suffit pas
            i = findfirst(k -> k.name === :freq && k.kind === :control, studio.knobs); studio.focus = i
            _tk(app, 'l'); _tscreen(app, tb, frame); @test q.step == 17
            _tk(app, 'Y'); _tscreen(app, tb, frame); @test q.step == 18
            _tk(app, 'D'); _tscreen(app, tb, frame); @test Ressac.drone_running(:sketch) && q.step == 18
            _tk(app, 'D'); _tscreen(app, tb, frame); @test q.step == 19
            _tk(app, 'U'); _tscreen(app, tb, frame)
            @test Ressac.current_workspace(app.workspaces).name == "PLAY" && p.step == 20   # la pane de PLAY est à jour
            @test occursin("Et ensuite", _tscreen(app, tb, frame)) && !p.finished
        finally
            cd(oldwd); Ressac._WAVE_RENDER[] = oldr; Ressac._WAVE_SYNC[] = olds; empty!(Ressac._DRONES)
        end
        # n sur la dernière étape termine ; p revient ; r recommence
        Ressac._focus_pane!(app, p)
        _tk(app, 'n'); @test p.finished
        @test occursin("Terminé", _tscreen(app, tb, frame))
        _tk(app, 'p'); @test !p.finished && p.step == 20
        _tk(app, 'r'); @test p.step == 1
        # sauter des étapes au clavier, défiler
        _tk(app, 'n'); _tk(app, 'n'); @test p.step == 3
        @test Ressac.serialize(p) == Dict{String,Any}("step" => 3)
        # :tutorial à nouveau : la pane existante repart du début, pas de doublon
        _tex(app, "tutorial")
        @test p.step == 1 && count(t -> t isa Ressac.TutorialPane,
                                   [t for l in Ressac._all_leaves(Ressac.current_workspace(app.workspaces).tree) for t in l.tabs]) == 1
    finally
        Ressac._LIVE_SCHEDULER[] = old
        empty!(Ressac._APP_MUTED_PATTERNS)
    end
end

@testset "tutoriel — toutes les étapes se rendent, restauration par kind" begin
    p = Ressac._pane_new(:tutorial, Dict{String,Any}("step" => 5))
    @test p isa Ressac.TutorialPane && p.step == 5
    tb = Tachikoma.TestBackend(60, 20)
    for i in 1:length(Ressac._TUTO_STEPS)
        p.step = i
        Ressac.render!(p, Tachikoma.Rect(1, 1, 60, 20), tb.buf)
        @test occursin(string(i, "/"), Tachikoma.row_text(tb, 1))
        @test all(y -> textwidth(rstrip(Tachikoma.row_text(tb, y))) <= 60, 1:20)
    end
    @test Ressac.pane_scope(p) === :tutorial && Ressac.title(p) == "tutoriel"
end
