include(joinpath(@__DIR__, "helpers.jl"))
# La cible d'un geste : les patterns pour e / E / m d'où qu'on soit ; la
# session pour :w, le son du curseur pour :save — roadmap U6, U7, puis
# l'écran unique (E2.1) et le son dans le texte.

# Une app en PLAY avec ses patterns et, à côté, une pane journal focalisée.
function _mt_app(text)
    app, frame = _new_app()
    _set_buffer!(app, text)
    Ressac._LIVE_SCHEDULER[] = app.scheduler
    Ressac.cmd_split!(app.workspaces, "log", Dict{String,Any}())
    Tachikoma.view(app, frame)
    @assert !(Ressac._focused_pane_impl(app) isa Ressac.EditorPane)
    return app, frame
end

@testset "cibles par mode" begin

    @testset "U6 — PLAY : e, E et m depuis une pane qui n'est pas le texte" begin
        app, frame = _mt_app("@d1 \"bd*4\"\n@d2 \"hh*8\"")
        try
            ed = Ressac._patterns_editor(app)
            @test ed !== nothing && Tachikoma.text(ed) == "@d1 \"bd*4\"\n@d2 \"hh*8\""
            ed.cursor_row = 1
            n = length(app.logs)
            _key!(app, 'e')
            @test Ressac.pattern_get(app.scheduler, :d1) !== nothing        # la ligne du curseur des patterns
            @test any(l -> occursin("éval ⇒", l), app.logs[(n + 1):end])
            @test !any(l -> occursin("ne marche que", l) || occursin("pas de patterns", l), app.logs[(n + 1):end])
            _key!(app, 'E')
            @test sort(Ressac.pattern_keys(app.scheduler)) == [:d1, :d2]
            _key!(app, 'm')
            @test Tachikoma.text(ed) == "# @d1 \"bd*4\"\n@d2 \"hh*8\""
            @test Ressac.pattern_keys(app.scheduler) == [:d2]
            # Le focus n'a pas bougé.
            @test !(Ressac._focused_pane_impl(app) isa Ressac.EditorPane)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "les patterns ne se ferment pas : c'est l'instrument" begin
        app, frame = _new_app()
        text = Tachikoma.text(Ressac._patterns_editor(app))
        for close! in (a -> _exec_ex_command!(a, "pclose"),
                       a -> (Tachikoma.update!(a, Tachikoma.KeyEvent(:ctrl, 'w')); _key!(a, 'c'); _key!(a, :escape)))
            close!(app)
            Tachikoma.view(app, frame)
            ed = Ressac._patterns_editor(app)
            @test ed !== nothing && Tachikoma.text(ed) == text
        end
        @test !app.quit
    end

    @testset ":w écrit la session, d'où qu'on soit ; :save et Espace W rangent le son du curseur" begin
        oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]
        Ressac._WAVE_RENDER[] = g -> (Float32[0.0f0, 0.1f0, 0.0f0], 44100); Ressac._WAVE_SYNC[] = true
        try
            app, frame = _new_app()
            Ressac._active_editor(app).mode = :normal
            _exec_ex_command!(app, "synth wmode")
            Tachikoma.view(app, frame)
            snd = Ressac._current_sound(app)
            @test snd !== nothing && snd.name == "wmode"
            @test Ressac._sound_write!(snd, "@synth :wmode (freq=220) saw(:freq) |> low_pass(700)")
            ed = Ressac._patterns_editor(app)
            synth_path = joinpath(pwd(), "plugins", "user-synths", "wmode.jl")
            session_path = joinpath(pwd(), "sessions", "wsess.txt")
            rm(synth_path; force = true); rm(session_path; force = true)
            # Le curseur dans le son, le clavier dans le texte puis dans sa DOC :
            # :w écrit la session (le texte entier, son compris), jamais le fichier du son.
            _exec_ex_command!(app, "son")
            Tachikoma.view(app, frame)
            sdoc = Ressac._sound_doc(app)
            @test sdoc !== nothing
            for focus! in (a -> Ressac._focus_patterns!(a), a -> Ressac._focus_pane!(a, sdoc))
                focus!(app)
                Tachikoma.view(app, frame)
                rm(session_path; force = true)
                @test Ressac._workspace_mode(app) === :design
                _exec_ex_command!(app, "w wsess")
                @test isfile(session_path) && read(session_path, String) == Tachikoma.text(ed)
                @test occursin("low_pass(700)", read(session_path, String))
                @test !isfile(synth_path)
            end
            @test app.session_name == "wsess"
            # :save range le son sous son nom ; les patterns autour n'y vont pas.
            Ressac._focus_patterns!(app)
            _exec_ex_command!(app, "save")
            @test isfile(synth_path)
            @test read(synth_path, String) == "@synth :wmode (freq=220) saw(:freq) |> low_pass(700)\n"
            # Espace W : le même geste.
            rm(synth_path; force = true)
            _key!(app, ' '); _key!(app, 'W')
            @test isfile(synth_path) && occursin("low_pass(700)", read(synth_path, String))
            # :save autre_nom : rangé sous ce nom, et le bloc du texte le prend.
            other_path = joinpath(pwd(), "plugins", "user-synths", "wautre.jl")
            rm(other_path; force = true)
            _exec_ex_command!(app, "save wautre")
            @test read(other_path, String) == "@synth :wautre (freq=220) saw(:freq) |> low_pass(700)\n"
            @test Ressac._current_sound(app).name == "wautre"
            @test !occursin(":wmode", Tachikoma.text(ed))
            # Le curseur hors du son : :w n'écrit toujours que la session.
            rm(other_path; force = true); rm(session_path; force = true)
            ed.cursor_row = 1; ed.cursor_col = 0
            @test Ressac._current_sound(app) === nothing
            _exec_ex_command!(app, "w")
            @test isfile(session_path) && !isfile(other_path)
        finally
            Ressac._WAVE_RENDER[] = oldr; Ressac._WAVE_SYNC[] = olds
        end
    end

    @testset "U7 — E et e lisent le même bloc, sur plusieurs lignes aussi" begin
        text = "base = \"bd*2\"\n@d1 stack(p\"bd*4\",\n          p\"hh*8\")\n@d2 \"cp\"\n    |> gain(0.5)\n# @d3 \"muet\""
        app, frame = _new_app()
        Ressac._LIVE_SCHEDULER[] = app.scheduler
        try
            _set_buffer!(app, text)
            n = length(app.logs)
            _key!(app, 'E')
            @test sort(Ressac.pattern_keys(app.scheduler)) == [:d1, :d2]
            @test !any(l -> occursin("[ERROR]", l), app.logs[(n + 1):end])
            @test length(Ressac.pattern_get(app.scheduler, :d1)(0 // 1, 1 // 1)) == 12      # les deux lignes du stack
            ev = only(Ressac.pattern_get(app.scheduler, :d2)(0 // 1, 1 // 1))
            @test ev.value[:gain] == 0.5
            # `e` sur la première ligne du bloc donne la même chose.
            Ressac.hush!(app.scheduler)
            _set_buffer!(app, text; row = 2)
            _key!(app, 'e')
            @test length(Ressac.pattern_get(app.scheduler, :d1)(0 // 1, 1 // 1)) == 12
            # …et sur sa seconde ligne aussi.
            Ressac.hush!(app.scheduler)
            _set_buffer!(app, text; row = 3)
            _key!(app, 'e')
            @test Ressac.pattern_get(app.scheduler, :d1) !== nothing
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end
end
