include(joinpath(@__DIR__, "helpers.jl"))
# La cible d'un geste : les patterns pour e / E / m d'où qu'on soit ; ce qui a
# le clavier pour :w — roadmap U6, U7, puis l'écran unique (E2.1).

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

    @testset ":w sauve ce qui a le clavier — le son dans le volet, la session à gauche" begin
        oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]
        Ressac._WAVE_RENDER[] = g -> (Float32[0.0f0, 0.1f0, 0.0f0], 44100); Ressac._WAVE_SYNC[] = true
        try
            app, frame = _new_app()
            Ressac._active_editor(app).mode = :normal
            _exec_ex_command!(app, "synth wmode")
            Tachikoma.view(app, frame)
            tab = Ressac._current_synth_tab(app)
            Ressac._edit_text!(tab.code_editor, "@synth :wmode (freq=220) saw(:freq) |> low_pass(700)\n")
            synth_path = joinpath(pwd(), "plugins", "user-synths", "wmode.jl")
            session_path = joinpath(pwd(), "sessions", "_last.txt")
            rm(session_path; force = true)
            # Sur chaque pane du volet (texte, DOC, studio), :w sauve le son.
            ws = Ressac.current_workspace(app.workspaces)
            for leaf in Ressac._all_leaves(app.volet_shown), i in eachindex(leaf.tabs)
                ws.focused_pane = leaf.id; leaf.current_tab = i
                Tachikoma.view(app, frame)                    # le studio suit le texte
                rm(synth_path; force = true)
                @test Ressac._workspace_mode(app) === :design
                _exec_ex_command!(app, "w")
                # (depuis le studio, c'est le génome sculpté qui s'écrit : `700.0`)
                @test isfile(synth_path) && occursin("low_pass(700", read(synth_path, String))
                @test !isfile(session_path)                               # pas une « session »
            end
            # Le clavier aux patterns : :w ne touche plus au son.
            Ressac._focus_patterns!(app)
            rm(synth_path; force = true)
            _exec_ex_command!(app, "w")
            @test !isfile(synth_path)
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
