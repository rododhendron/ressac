include(joinpath(@__DIR__, "helpers.jl"))
# Les sessions avec les verbes de vim, et la réserve — étape E3.

_ss_text(app) = Tachikoma.text(Ressac._patterns_editor(app))
# Chaque cas repart d'un dossier de sessions vide (le bac à sable est partagé).
function _ss_app()
    rm(Ressac._sessions_dir(); recursive = true, force = true)
    rm(Ressac._session_state_path(); force = true)
    return _new_app()
end
function _ss_type!(app, text)
    Ressac._edit_text!(Ressac._patterns_editor(app), text)
end

@testset "sessions et réserve" begin

    @testset ":w demande un nom, :w nom range, :w ensuite sauve dessous" begin
        app, _ = _ss_app()
        @test !Ressac._session_dirty(app)                         # un écran neuf n'a rien à sauver
        _ss_type!(app, "@d1 p\"bd sn\"")
        @test Ressac._session_dirty(app) && Ressac._session_label(app) == "sans nom +"
        logs = _cmd_logs(app, "w")
        @test any(l -> occursin("n'a pas de nom", l), logs) && isempty(Ressac.list_sessions())
        _exec_ex_command!(app, "w brin")
        @test Ressac.list_sessions() == ["brin"] && app.session_name == "brin"
        @test read(Ressac._session_path("brin"), String) == "@d1 p\"bd sn\""
        @test !Ressac._session_dirty(app) && Ressac._session_label(app) == "brin"
        _ss_type!(app, "@d1 p\"bd sn cp\"")
        _exec_ex_command!(app, "w")
        @test read(Ressac._session_path("brin"), String) == "@d1 p\"bd sn cp\""
        # Un nom qui sortirait du dossier est refusé.
        @test any(l -> occursin("un nom de session", l), _cmd_logs(app, "w ../ailleurs"))
        @test Ressac.list_sessions() == ["brin"]
    end

    @testset ":e ouvre une autre session sans rien couper, :e # y revient" begin
        rm(Ressac._sessions_dir(); recursive = true, force = true)
        _with_live_app() do app, _
            _ss_type!(app, "@d1 p\"bd\"")
            _exec_ex_command!(app, "w un")
            _key!(app, 'E')
            _ss_type!(app, "@d2 p\"cp\"")
            _exec_ex_command!(app, "w deux")
            _exec_ex_command!(app, "e un")
            @test _ss_text(app) == "@d1 p\"bd\"" && app.session_name == "un" && app.session_prev == "deux"
            @test Ressac.pattern_get(app.scheduler, :d1) !== nothing        # ce qui jouait continue
            @test !Ressac._session_dirty(app)
            _exec_ex_command!(app, "e #")
            @test app.session_name == "deux" && _ss_text(app) == "@d2 p\"cp\""
            @test any(l -> occursin("pas de session « nulle »", l), _cmd_logs(app, "e nulle"))
            @test app.session_name == "deux"
        end
    end

    @testset "ce qui n'est pas sauvé n'est pas jeté sans le dire" begin
        app, _ = _ss_app()
        _ss_type!(app, "@d1 p\"bd\"")
        _exec_ex_command!(app, "w un")
        _ss_type!(app, "@d1 p\"bd\"\n@d2 p\"pas sauvé\"")
        logs = _cmd_logs(app, "enew")
        @test any(l -> occursin(":w d'abord", l), logs) && occursin("pas sauvé", _ss_text(app))
        @test any(l -> occursin(":w d'abord", l), _cmd_logs(app, "e un"))
        _exec_ex_command!(app, "e!")                               # relit depuis le disque
        @test _ss_text(app) == "@d1 p\"bd\"" && !Ressac._session_dirty(app)
        _ss_type!(app, "brouillon")
        _exec_ex_command!(app, "enew!")
        @test _ss_text(app) == "" && app.session_name == "" && app.session_prev == "un"
        @test !Ressac._session_dirty(app)
    end

    @testset ":w écrit toujours la session, sons compris ; :save range le son dans la réserve" begin
        app, _ = _ss_app()
        reserve = joinpath(pwd(), "plugins", "user-synths", "wsess.jl")
        rm(reserve; force = true)
        _ss_type!(app, "@d1 p\"bd\"")
        _exec_ex_command!(app, "w maison")
        _exec_ex_command!(app, "synth wsess")                      # le son arrive dans le texte, le curseur dessus
        snd = Ressac._current_sound(app)
        @test snd !== nothing && snd.name == "wsess"
        @test Ressac._session_dirty(app)
        logs = _cmd_logs(app, "w")
        @test !isfile(reserve)                                     # :w ne range pas le son
        @test read(Ressac._session_path("maison"), String) == _ss_text(app)
        @test occursin("@synth :wsess", read(Ressac._session_path("maison"), String))
        @test any(l -> occursin("wsess", l) && occursin(":save", l), logs)   # et dit comment le ranger
        @test Ressac.list_sessions() == ["maison"] && !Ressac._session_dirty(app)
        _exec_ex_command!(app, "w wsess")                          # un nom : celui d'une session, pas d'un son
        @test Ressac.list_sessions() == ["maison", "wsess"] && !isfile(reserve)
        _exec_ex_command!(app, "save")
        @test read(reserve, String) == Ressac._sound_text(snd) * "\n"
        @test Ressac.list_sessions() == ["maison", "wsess"]        # pas une session de plus
        # :e! relit la session, même le curseur dans un son.
        Ressac._sound_write!(snd, "@synth :wsess (freq=220) saw(:freq)")
        @test Ressac._current_sound(app) !== nothing && Ressac._session_dirty(app)
        _exec_ex_command!(app, "e!")
        @test _ss_text(app) == read(Ressac._session_path("wsess"), String)
        @test occursin("sin_osc(:freq)", _ss_text(app)) && !Ressac._session_dirty(app)
    end

    @testset "d'un lancement à l'autre : le nom de la session, et si elle était sauvée" begin
        app, _ = _ss_app()
        _ss_type!(app, "@d1 p\"bd\"")
        _exec_ex_command!(app, "w hier")
        Ressac._session_state_save!(app)
        @test read(Ressac._session_path("_last"), String) == "@d1 p\"bd\""   # la copie de sûreté
        @test !("_last" in Ressac.list_sessions())
        app2, _ = _new_app()
        _ss_type!(app2, "@d1 p\"bd\"")                             # le texte, lui, revient avec la disposition
        Ressac._session_state_restore!(app2)
        @test app2.session_name == "hier" && !Ressac._session_dirty(app2)
        # Une session dont le fichier a disparu ne laisse pas un nom fantôme.
        rm(Ressac._session_path("hier"))
        app3, _ = _new_app()
        Ressac._session_state_restore!(app3)
        @test app3.session_name == ""
    end

    @testset "la status line dit la session, et qu'elle a changé" begin
        app, frame = _ss_app()
        row() = (Tachikoma.reset!(frame.buffer); Tachikoma.view(app, frame);
                 join(frame.buffer.content[Tachikoma.buf_index(frame.buffer, x, 1)].char for x in 1:frame.buffer.area.width))
        @test occursin("sans nom", row()) && !occursin("sans nom +", row())
        _ss_type!(app, "@d1 p\"bd\"")
        @test occursin("sans nom +", row())
        _exec_ex_command!(app, "w brin")
        @test occursin("brin", row()) && !occursin("brin +", row())
    end

    @testset "la réserve : quatre onglets, Tab passe de l'un à l'autre" begin
        app, _ = _ss_app()
        _exec_ex_command!(app, "réserve")
        @test app.modal === :patterns                              # les motifs, par défaut
        @test [t[2] for t in Ressac._RESERVE_TABS] == ["sons", "motifs", "sessions", "recettes"]
        _key!(app, :tab);     @test app.modal === :sessions
        _key!(app, :tab);     @test app.modal === :snippets
        _key!(app, :tab);     @test app.modal === :synth_library
        _key!(app, :backtab); @test app.modal === :snippets
        _key!(app, :escape);  @test app.modal === :none
        Tachikoma.view(app, _new_app()[2])                         # (la vue note le dernier onglet)
        # Les entrées d'avant mènent à leur onglet.
        _exec_ex_command!(app, "sessions"); @test app.modal === :sessions
        _key!(app, :escape)
        _exec_ex_command!(app, "lib");      @test app.modal === :synth_library
        _key!(app, :escape)
    end

    @testset "l'onglet des sessions : ouvrir, supprimer" begin
        app, _ = _ss_app()
        _ss_type!(app, "@d1 p\"a\""); _exec_ex_command!(app, "w alpha")
        _ss_type!(app, "@d1 p\"b\""); _exec_ex_command!(app, "w beta")
        _exec_ex_command!(app, "sessions")
        @test Ressac._sessions_sync!(app) == ["alpha", "beta"]
        _key!(app, :enter)                                          # la première : alpha
        @test app.modal === :none && app.session_name == "alpha" && _ss_text(app) == "@d1 p\"a\""
        _exec_ex_command!(app, "sessions")
        _key!(app, 'j'); _key!(app, 'x')                            # supprime beta
        @test Ressac.list_sessions() == ["alpha"]
    end

    @testset "un motif s'écoute avant d'être posé, et se pose dans les patterns" begin
        _with_live_app() do app, frame
            _ss_type!(app, "@d1 p\"bd bd\"\n@d2 p\"hh*8\" |> gain(0.4)")
            ed = Ressac._patterns_editor(app); ed.cursor_row = 2
            _exec_ex_command!(app, "keep charley")                  # la ligne entière : son et effets
            @test Ressac.load_pattern("charley").code == "@d2 p\"hh*8\" |> gain(0.4)"
            _ss_type!(app, "@d1 p\"bd bd\"")
            _exec_ex_command!(app, "réserve")
            _key!(app, ' ')                                         # écoute
            preview = Symbol("d", Ressac._PREVIEW_SLOT)
            @test Ressac.pattern_get(app.scheduler, preview) !== nothing
            @test Ressac.pattern_get(app.scheduler, :d2) === nothing   # rien n'a été posé
            _key!(app, ' ')
            @test Ressac.pattern_get(app.scheduler, preview) === nothing
            # Sortir de la réserve arrête l'écoute.
            _key!(app, ' '); _key!(app, :escape); Tachikoma.view(app, frame)
            @test Ressac.pattern_get(app.scheduler, preview) === nothing
            # Entrée le pose sur son slot ; depuis le volet d'un son aussi, dans les patterns.
            _exec_ex_command!(app, "son")
            _exec_ex_command!(app, "réserve"); _key!(app, :enter)
            @test occursin("@d2 p\"hh*8\" |> gain(0.4)", _ss_text(app))
            @test Ressac.pattern_get(app.scheduler, :d2) !== nothing
            @test Ressac._focused_role(app) === :patterns
        end
    end

    @testset "Espace k ouvre la commande sur :keep" begin
        app, _ = _ss_app()
        _ss_type!(app, "@d1 p\"bd\"")
        Ressac._patterns_editor(app).cursor_row = 1
        _key!(app, ' '); _key!(app, 'k')
        @test Ressac.is_active(app.command_line) && Ressac.current_text(app.command_line) == "keep "
    end
end
