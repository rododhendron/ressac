include(joinpath(@__DIR__, "helpers.jl"))
# L'écran unique : le volet à droite des patterns, le chrome — étapes E2.1, E2.7, E2.8.

function _vl_app(w::Int, h::Int = 40)
    app = Ressac.RessacApp(; scheduler = Ressac.Scheduler(MockOSCClient(); cps = 0.5))
    tb = Tachikoma.TestBackend(w, h)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, w, h), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    Ressac._PANE_MODE.active = false
    Ressac._active_editor(app).mode = :normal
    return app, tb, frame
end
_vl_panes(app) = [typeof(t) for l in Ressac._all_leaves(Ressac.current_workspace(app.workspaces).tree) for t in l.tabs]
_vl_rows(tb, h = 40) = [Tachikoma.row_text(tb, y) for y in 1:h]

@testset "écran unique" begin

    @testset "sur un écran ordinaire, le son remplace la fiche" begin
        app, tb, frame = _vl_app(140)
        @test Ressac.DocPane in _vl_panes(app)
        _exec_ex_command!(app, "son"); Tachikoma.view(app, frame)
        @test !(Ressac.DocPane in _vl_panes(app))
        @test Ressac._focused_role(app) === :synth
    end

    @testset "sur un grand écran, le son s'ouvre entre les patterns et la fiche" begin
        app, tb, frame = _vl_app(Ressac._VOLET_WIDE_COLS + 20)
        _exec_ex_command!(app, "son"); Tachikoma.view(app, frame)
        @test Ressac.DocPane in _vl_panes(app)                 # la fiche est toujours là
        root = Ressac.current_workspace(app.workspaces).tree
        @test root.children[1] === Ressac._patterns_leaf(Ressac.current_workspace(app.workspaces))
        @test root.children[2] isa Ressac.Container && root.children[2].direction === :h   # son | fiche
        @test Ressac._focused_role(app) === :synth
        # Le fermer rend toute la colonne à la fiche.
        _exec_ex_command!(app, "back"); Tachikoma.view(app, frame)
        @test Ressac.current_workspace(app.workspaces).tree.children[2] isa Ressac.PaneLeaf
    end

    @testset "la fenêtre change de taille : le son suit" begin
        app, tb, frame = _vl_app(140)
        _exec_ex_command!(app, "son"); Tachikoma.view(app, frame)
        ed = Ressac._active_editor(app)
        wide_tb = Tachikoma.TestBackend(230, 40)
        wide = Tachikoma.Frame(wide_tb.buf, Tachikoma.Rect(1, 1, 230, 40), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
        Tachikoma.view(app, wide); Tachikoma.view(app, wide)
        @test Ressac.DocPane in _vl_panes(app)
        @test Ressac._active_editor(app) === ed                  # le clavier n'a pas bougé
        Tachikoma.view(app, frame); Tachikoma.view(app, frame)
        @test !(Ressac.DocPane in _vl_panes(app))
        @test Ressac._active_editor(app) === ed
    end

    @testset "une commande qui parle d'un son l'ouvre à droite" begin
        app, tb, frame = _vl_app(140)
        @test app.volet === :fiche
        _exec_ex_command!(app, "explain")
        @test app.volet === :son
        # Une commande de patterns, elle, ne touche pas au volet.
        _exec_ex_command!(app, "back")
        _exec_ex_command!(app, "mixer")
        @test app.volet === :fiche
    end

    @testset "chrome — une status line, une barre de touches, une ligne de journal" begin
        app, tb, frame = _vl_app(140)
        rows = _vl_rows(tb)
        @test occursin("RESSAC", rows[1]) && occursin("120 bpm", rows[1]) && occursin("cycle", rows[1])
        @test occursin("? aide", rows[39])
        @test isempty(strip(rows[40]))                           # rien à dire : la ligne est vide
        @test isempty(app.logs)                                  # plus de message d'accueil permanent
        Ressac._push_app_log!(app, "[INFO] d3 modifié")
        Tachikoma.reset!(tb.buf); Tachikoma.view(app, frame)
        @test occursin("d3 modifié", _vl_rows(tb)[40])
        # Le texte de départ dit vrai : l'app s'ouvre en mode normal, E suffit.
        @test occursin("E joue ces lignes", _buffer_text(app)) && !occursin("Esc puis E", _buffer_text(app))
    end

    @testset "SuperCollider répond-il ? — on ne dit que ce qu'on sait" begin
        running = Ressac._SCOPE_LISTENER_RUNNING[]; seen = Ressac._SC_LAST_SEEN[]; ping = Ressac._SC_LAST_PING[]
        try
            Ressac._SCOPE_LISTENER_RUNNING[] = false
            @test Ressac._sc_state() === :unknown                # pas d'écoute : rien n'est affirmé
            app, tb, frame = _vl_app(140)
            @test !occursin(" SC", _vl_rows(tb)[1])
            @test isempty(app.scheduler.osc.sent)                # et aucun ping n'est parti
            Ressac._SCOPE_LISTENER_RUNNING[] = true
            Ressac._SC_LAST_SEEN[] = time()
            @test Ressac._sc_state() === :alive
            Tachikoma.reset!(tb.buf); Tachikoma.view(app, frame)
            @test occursin("● SC", _vl_rows(tb)[1])
            Ressac._SC_LAST_SEEN[] = time() - 60
            @test Ressac._sc_state() === :silent
            Tachikoma.reset!(tb.buf); Tachikoma.view(app, frame)
            @test occursin("○ SC ne répond pas", _vl_rows(tb)[1])
            # Un ping toutes les deux secondes, pas un par image.
            mock = MockOSCClient()
            Ressac._SC_LAST_PING[] = 0.0
            @test Ressac._sc_ping!(mock, 100.0)
            @test !Ressac._sc_ping!(mock, 100.5)
            @test Ressac._sc_ping!(mock, 102.5)
            @test length(mock.sent) == 2
            @test Ressac.decode_message(mock.sent[1]).address == "/ressac/ping"
        finally
            Ressac._SCOPE_LISTENER_RUNNING[] = running; Ressac._SC_LAST_SEEN[] = seen; Ressac._SC_LAST_PING[] = ping
        end
    end
end
