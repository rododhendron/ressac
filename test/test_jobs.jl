include(joinpath(@__DIR__, "helpers.jl"))
# Le travail lent hors de la tâche UI — roadmap U10.

@testset "travaux de fond" begin

    @testset "_background! : le résultat revient sur la tâche UI, à la frame suivante" begin
        app, frame = _new_app()
        Ressac._JOBS_INLINE[] = false
        try
            gate = Channel{Nothing}(1)
            got = Ref{Any}(:rien)
            ui_task = current_task()
            done_on = Ref{Any}(nothing)
            Ressac._background!(() -> (take!(gate); 42)) do result, err
                got[] = (result, err); done_on[] = current_task()
            end
            # Tant que le travail n'a pas fini, rien n'est appliqué — et l'appel n'a pas bloqué.
            Tachikoma.view(app, frame)
            @test got[] === :rien && Ressac._jobs_busy()
            put!(gate, nothing)
            @test timedwait(() -> Ressac._JOBS_PENDING[] == 0, 10.0) === :ok
            @test got[] === :rien                                # fini, mais pas encore appliqué
            Tachikoma.view(app, frame)                            # la vue vide la file
            @test got[] == (42, nothing) && done_on[] === ui_task
            @test !Ressac._jobs_busy()
            # Une erreur du travail arrive à `done`, pas dans la boucle de l'app.
            Ressac._background!(() -> error("réseau coupé")) do result, err
                got[] = (result, err)
            end
            @test timedwait(() -> Ressac._JOBS_PENDING[] == 0, 10.0) === :ok
            Tachikoma.view(app, frame)
            @test got[][1] === nothing && got[][2] isa ErrorException
            # Une suite qui lève se lit dans le journal ; l'app continue.
            Ressac._background!((r, e) -> error("suite cassée"), () -> 1)
            @test timedwait(() -> Ressac._JOBS_PENDING[] == 0, 10.0) === :ok
            Tachikoma.view(app, frame)
            @test any(l -> occursin("[ERROR] tâche de fond — ", l) && occursin("suite cassée", l), app.logs)
        finally
            Ressac._JOBS_INLINE[] = true
        end
    end

    @testset "sccode : la modale s'ouvre tout de suite, la liste arrive après" begin
        app, frame = _new_app()
        Ressac._active_editor(app).mode = :normal
        gate = Channel{Nothing}(1)
        _SCCODE_PAGES["https://sccode.org/?page=1"] = "placeholder"
        old = Ressac._SCCODE_GET[]
        Ressac._SCCODE_GET[] = url -> (take!(gate);
            "<a class=\"object\" href=\"/1-AbC\">Un pad</a><a class=\"object\" href=\"/1-DeF\">Une basse</a>")
        Ressac._JOBS_INLINE[] = false
        try
            _exec_ex_command!(app, "sccode")
            # Pas de gel : la modale est là, en chargement, et l'app répond aux touches.
            @test app.modal === :sccode && app.sccode_loading && isempty(app.sccode_entries)
            Tachikoma.view(app, frame)
            put!(gate, nothing)
            @test timedwait(() -> Ressac._JOBS_PENDING[] == 0, 10.0) === :ok
            Tachikoma.view(app, frame)
            @test !app.sccode_loading && [e.id for e in app.sccode_entries] == ["1-AbC", "1-DeF"]
            # Une réponse en retard pour une demande dépassée est ignorée.
            Ressac._sccode_load_page!(app, 2)
            Ressac._sccode_load_page!(app, 3)
            put!(gate, nothing); put!(gate, nothing)
            @test timedwait(() -> Ressac._JOBS_PENDING[] == 0, 10.0) === :ok
            Tachikoma.view(app, frame)
            @test app.sccode_page == 3 && !app.sccode_loading
        finally
            Ressac._JOBS_INLINE[] = true
            Ressac._SCCODE_GET[] = old
            delete!(_SCCODE_PAGES, "https://sccode.org/?page=1")
        end
    end

    @testset "sccode : importer ne garde qu'un nom de synth valide" begin
        app, frame = _new_app()
        Ressac._active_editor(app).mode = :normal
        with_clean_registries() do
            # Pas de SynthDef : rien à importer, et c'est dit.
            _SCCODE_PAGES["https://sccode.org/1-zz9"] = "<pre>1</pre><pre>{ SinOsc.ar(220) }.play;</pre>"
            n = length(app.logs)
            Ressac._sccode_import!(app, "1-zz9")
            @test any(l -> occursin("pas de SynthDef", l), app.logs[(n + 1):end])
            @test !isdir(joinpath(pwd(), "plugins", "user-synths")) || isempty(filter(f -> startswith(f, "sccode_1_zz9"), readdir(joinpath(pwd(), "plugins", "user-synths"))))
            # Un SynthDef dont le nom n'est pas un identifiant : nom dérivé de l'id.
            empty!(Ressac._SCCODE_SOURCE_CACHE)
            _SCCODE_PAGES["https://sccode.org/1-zz9"] = "<pre>1</pre><pre>SynthDef(\\9vies, { |out=0| Out.ar(out, SinOsc.ar(220)) }).add;</pre>"
            try
                closed = Ref("")
                Ressac._sccode_import!(app, "1-zz9"; then = name -> (closed[] = name))
                @test closed[] == "sccode_1_zz9"                       # nom dérivé de l'id, sans tiret
                @test isfile(joinpath(pwd(), "plugins", "user-synths", "sccode_1_zz9.jl"))
                Ressac._sccode_import!(app, "1-zz9"; then = name -> (closed[] = name))
                @test closed[] == "sccode_1_zz9_2" && Ressac.SynthDSL.valid_synth_name(closed[])
            finally
                delete!(_SCCODE_PAGES, "https://sccode.org/1-zz9")
                empty!(Ressac._SCCODE_SOURCE_CACHE)
            end
        end
    end

    @testset ":vsplit d'un type inconnu se dit dans le journal" begin
        app, frame = _new_app()
        Ressac._active_editor(app).mode = :normal
        n_leaves = length(Ressac._all_leaves(Ressac.current_workspace(app.workspaces).tree))
        for verb in ("vsplit", "hsplit")
            logs = _cmd_logs(app, "$verb bogus")
            @test any(l -> occursin("[ERROR] :$verb — type de pane inconnu « bogus »", l) && occursin("editor", l), logs)
        end
        @test length(Ressac._all_leaves(Ressac.current_workspace(app.workspaces).tree)) == n_leaves
        _exec_ex_command!(app, "vsplit log")
        @test length(Ressac._all_leaves(Ressac.current_workspace(app.workspaces).tree)) == n_leaves + 1
    end

    @testset ":prune mesure en fond et n'applique que sur le texte mesuré" begin
        oldr = Ressac._WAVE_RENDER[]; olds = Ressac._WAVE_SYNC[]; old_an = Ressac._PRUNE_ANALYZE[]
        Ressac._WAVE_RENDER[] = g -> (Float32[0.0f0, 0.1f0, 0.0f0], 44100); Ressac._WAVE_SYNC[] = true
        gate = Channel{Nothing}(1)
        # Une fausse analyse : attend le feu vert, puis rend des descripteurs identiques
        # partout (tout nœud non essentiel est alors « inaudible »).
        Ressac._PRUNE_ANALYZE[] = gs -> (take!(gate); [fill(0.5, Ressac.N_DESCRIPTORS) for _ in gs])
        app, frame = _new_app()
        Ressac._active_editor(app).mode = :normal
        Ressac._JOBS_INLINE[] = false
        try
            _exec_ex_command!(app, "synth fondprune")
            Tachikoma.view(app, frame)
            tab = Ressac._current_synth_tab(app)
            text = "@synth :fondprune (freq=220) saw(:freq) |> low_pass(900) |> tanh_drive(1)\n"
            Ressac._edit_text!(tab.code_editor, text)
            _exec_ex_command!(app, "prune")
            @test Ressac._jobs_busy()                                # la mesure tourne, la commande a rendu la main
            @test any(l -> occursin("mesure en cours", l), app.logs)
            # Le joueur retouche le texte pendant la mesure : son résultat ne s'applique pas.
            Ressac._edit_text!(tab.code_editor, replace(Tachikoma.text(tab.code_editor), "900" => "1200"))
            edited = Tachikoma.text(tab.code_editor)
            put!(gate, nothing)
            @test timedwait(() -> Ressac._JOBS_PENDING[] == 0, 10.0) === :ok
            Tachikoma.view(app, frame)
            @test Tachikoma.text(tab.code_editor) == edited
            @test any(l -> occursin("le texte a changé pendant la mesure", l), app.logs)
        finally
            Ressac._JOBS_INLINE[] = true
            Ressac._PRUNE_ANALYZE[] = old_an
            Ressac._WAVE_RENDER[] = oldr; Ressac._WAVE_SYNC[] = olds
        end
    end
end
