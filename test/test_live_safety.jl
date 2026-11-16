include(joinpath(@__DIR__, "helpers.jl"))
# Ne jamais tomber en live — phase 1 de la roadmap.
#
# Ce qui peut couper le son ou fermer la session pendant qu'on joue : un
# pattern qui lève, un tempo absurde, un retard de la boucle, un geste de
# souris ou un rendu qui lève, un slot qui se désigne lui-même.

# Une pane dont tout lève : sert à vérifier les filets de l'app.
struct _BoomPane <: Ressac.PaneImpl end
Ressac.render!(::_BoomPane, area, buf) = error("rendu cassé")
Ressac.handle_key!(::_BoomPane, evt) = error("touche cassée")
Ressac.handle_mouse!(::_BoomPane, evt) = error("souris cassée")
Ressac.title(::_BoomPane) = "boom"

# Fait tourner le scheduler sur exactement `cycles` cycles : la dernière
# fenêtre s'arrête pile à la frontière (demi-ouverte).
function _run!(s, cycles; dt = 0.05)
    stop = cycles / s.cps - s.lookahead
    for t in 0.0:dt:(stop - dt / 2); Ressac._step!(s, t); end
    Ressac._step!(s, stop)
end

# Un pattern qui joue `bd` au cycle 0 puis lève à partir du cycle 1.
_faulty() = Pattern{Symbol}((s, e) -> s >= 1 ? error("boum au cycle $(floor(Int, s))") :
                                     Event{Symbol}[Event{Symbol}(0 // 1, 1 // 1, :bd)])

# Nombre de messages dont le son est `name` parmi ceux envoyés.
_count_sound(mock, name) = count(b -> occursin("\0$(name)\0", String(copy(b))), mock.sent)

@testset "live — sécurité" begin

    @testset "L1 — un slot qui lève n'emporte pas les autres" begin
        Ressac._drain_notices!()
        mock = MockOSCClient()
        s = Scheduler(mock; cps = 1.0); s.t_start = 0.0
        set_pattern!(s, :d1, _faulty())             # lève au cycle 1
        set_pattern!(s, :d2, p"hh*4")
        set_pattern!(s, :d3, p"cp*2")
        _run!(s, 3)
        # Les voisins ont joué leurs trois cycles complets, quel que soit
        # l'ordre d'itération des slots.
        @test _count_sound(mock, "hh") == 12
        @test _count_sound(mock, "cp") == 6
        # Le slot fautif est retiré et annoncé une seule fois.
        @test sort(Ressac.pattern_keys(s)) == [:d2, :d3]
        notices = Ressac._drain_notices!()
        @test count(l -> occursin("@d1 coupé", l), notices) == 1
        @test occursin("boum au cycle 1", only(filter(l -> occursin("@d1", l), notices)))
        @test _count_sound(mock, "bd") == 1         # ce qu'il a joué avant de lever est parti
    end

    @testset "L1 — un slot réévalué entre-temps n'est pas retiré" begin
        mock = MockOSCClient()
        s = Scheduler(mock; cps = 1.0)
        bad = _faulty(); good = p"sn"
        set_pattern!(s, :d1, good)
        Ressac._evict_faulty_slot!(s, :d1, bad, ErrorException("x"))
        @test Ressac.pattern_get(s, :d1) === good
    end

    @testset "L8 — une valeur sans forme OSC coupe son slot avec un message clair" begin
        Ressac._drain_notices!()
        mock = MockOSCClient()
        s = Scheduler(mock; cps = 1.0); s.t_start = 0.0
        set_pattern!(s, :d1, p"0 1" + 1)            # Pattern{Any} de nombres
        set_pattern!(s, :d2, p"hh*4")
        _run!(s, 1)
        @test _count_sound(mock, "hh") == 4
        @test any(l -> occursin("@d1 coupé", l) && occursin("il manque un son", l),
                  Ressac._drain_notices!())
    end

    @testset "L8 — un Pattern{Any} de sons ou de contrôles se joue" begin
        anyp(p) = Pattern{Any}((a, b) -> Event{Any}[Event{Any}(e.start, e.stop, e.value) for e in p(a, b)])
        mock = MockOSCClient()
        s = Scheduler(mock; cps = 1.0); s.t_start = 0.0
        set_pattern!(s, :d1, anyp(p"bd*2"))
        set_pattern!(s, :d2, anyp(p"hh*4" |> gain(0.5)))
        set_pattern!(s, :d3, anyp(p"cp") |> gain(0.5))      # contrôle par-dessus
        _run!(s, 1)
        @test _count_sound(mock, "bd") == 2
        @test _count_sound(mock, "hh") == 4
        @test _count_sound(mock, "cp") == 1
        @test sort(Ressac.pattern_keys(s)) == [:d1, :d2, :d3]
    end

    @testset "L9 — une note non numérique ne fait pas lever le pas" begin
        mock = MockOSCClient()
        s = Scheduler(mock; cps = 1.0); s.t_start = 0.0
        set_pattern!(s, :d1, p"bd*2" |> set(:note, :foo))
        Ressac._step!(s, 0.0)
        @test Ressac.pattern_get(s, :d1) !== nothing
    end

    @testset "L2 — changer de tempo ne rejoue pas le lookahead" begin
        mock = MockOSCClient()
        s = Scheduler(mock; cps = 1.0, lookahead = 0.05)
        set_pattern!(s, :d1, Pattern{Symbol}((a, b) ->
            a <= 3//100 < b ? [Event{Symbol}(3//100, 1//1, :bd)] : Event{Symbol}[]))
        s.t_start = time()
        Ressac._step!(s, 0.0)                       # fenêtre [0, 0.05) : l'événement part
        @test length(mock.sent) == 1
        set_cps!(s, 1.5)
        Ressac._step!(s, time() - s.t_start)
        @test length(mock.sent) == 1                # pas de flam
        @test s.last_end_cycles >= 0.05
    end

    @testset "L2 — la position en cycles est conservée à travers le changement" begin
        s = Scheduler(MockOSCClient(); cps = 2.0)
        s.t_start = time() - 10.0                   # 20 cycles écoulés
        s.last_end_cycles = 20.0
        set_cps!(s, 0.5)
        @test isapprox((time() - s.t_start) * s.cps, 20.0; atol = 0.05)
    end

    @testset "L3 — cps fini et borné, à toutes les entrées" begin
        s = Scheduler(MockOSCClient(); cps = 0.5)
        for bad in (Inf, -Inf, NaN, 0.0, -1.0, 1e9)
            @test_throws ArgumentError set_cps!(s, bad)
            @test_throws ArgumentError Scheduler(MockOSCClient(); cps = bad)
        end
        @test s.cps == 0.5
        set_cps!(s, Ressac._CPS_MAX); @test s.cps == Ressac._CPS_MAX

        # Depuis l'OSC externe : refusé, annoncé, le scheduler reste sain.
        _with_test_scheduler() do mock, sched
            Ressac._drain_notices!()
            Ressac._handle_external_set!(Any["cps", Inf])
            @test sched.cps == 0.5
            @test any(l -> occursin("/ressac/set cps refusé", l), Ressac._drain_notices!())
            Ressac._handle_external_set!(Any["cps", 0.75])
            @test sched.cps == 0.75
        end

        # Depuis la barre de commande : erreur lisible, tempo intact, l'app rend.
        app, frame = _new_app()
        Ressac._active_editor(app).mode = :normal
        _exec_ex_command!(app, "cps Inf")
        @test app.scheduler.cps == 0.5
        @test any(l -> occursin("[ERROR] cps", l), app.logs)
        Tachikoma.view(app, frame)
        @test !any(l -> occursin("[ERROR] affichage", l), app.logs)
    end

    @testset "L4 — après un gel, la boucle live reprend au présent" begin
        Ressac._drain_notices!()
        mock = MockOSCClient()
        s = Scheduler(mock; cps = 1.0, lookahead = 0.05)
        set_pattern!(s, :d1, p"bd*4")
        s.t_start = time() - 3600.0                 # une heure de retard
        s.last_end_cycles = 0.0
        Ressac._tick!(s)
        # Au plus la fenêtre de rattrapage + le lookahead, pas 14 400 bundles.
        @test length(mock.sent) <= ceil(Int, 4 * (Ressac._CATCHUP_MAX + 0.05)) + 1
        @test isapprox(s.last_end_cycles, 3600.05; atol = 0.1)
        @test any(l -> occursin("scheduler en retard", l), Ressac._drain_notices!())
        # En régime normal : pas de saut, pas d'annonce.
        n = length(mock.sent)
        Ressac._tick!(s)
        @test length(mock.sent) - n <= 1
        @test isempty(Ressac._drain_notices!())
    end

    @testset "L4 — _step! (tests, rendu hors-ligne) rattrape tout" begin
        mock = MockOSCClient()
        s = Scheduler(mock; cps = 1.0); s.t_start = 0.0
        set_pattern!(s, :d1, p"bd*4")
        Ressac._step!(s, 9.95)
        @test length(mock.sent) == 40
    end

    @testset "L7 — slot() : auto-référence, détour, lecture sous verrou" begin
        _with_test_scheduler(; cps = 1.0) do mock, s
            s.t_start = 0.0
            set_pattern!(s, :d1, p"bd*4" |> duck(slot(1)))       # se désigne lui-même
            set_pattern!(s, :d2, p"hh*4" |> duck(slot(3)))       # d2 → d3 → d2
            set_pattern!(s, :d3, p"cp*2" |> duck(slot(2)))
            set_pattern!(s, :d4, slot(2) |> fast(2) |> speed(2)) # l'exemple de la docstring
            _run!(s, 1)
            @test sort(Ressac.pattern_keys(s)) == [:d1, :d2, :d3, :d4]
            @test _count_sound(mock, "bd") == 4
            @test _count_sound(mock, "hh") == 4 + 8              # d2, et d4 qui le rejoue ×2
            @test _count_sound(mock, "cp") == 2
            # La pile des slots ouverts est rendue vide.
            @test isempty(get(task_local_storage(), :ressac_open_slots, Symbol[]))
        end
        # Slot vide ou pas de session : silence.
        @test isempty(slot(9)(0//1, 1//1))
    end

    @testset "L12 — start! ne lance qu'une boucle" begin
        s = Scheduler(MockOSCClient(); cps = 1.0)
        start!(s)
        t0 = s.t_start
        start!(s)                                   # sans effet
        @test s.t_start == t0
        @test stop!(s; wait_for = 5.0) === true
    end

    @testset "L12 — notes jouées et destinataires OSC sous verrou" begin
        Ressac.push_played_note!(60)
        snap = Ressac._played_notes()
        @test !isempty(snap) && snap !== Ressac._LAST_NOTES[]
        got = Ref{Any}(nothing)
        Ressac.osc_reply_handler!(args -> (got[] = args), "/ressac/test-reply")
        @test Ressac._osc_reply_handler("/ressac/test-reply") !== nothing
        Ressac.osc_reply_handler_remove!("/ressac/test-reply")
        @test Ressac._osc_reply_handler("/ressac/test-reply") === nothing
    end

    @testset "la file des notices est bornée" begin
        Ressac._drain_notices!()
        for i in 1:(Ressac._NOTICE_MAX + 50); Ressac._notify!("n$i"); end
        lines = Ressac._drain_notices!()
        @test length(lines) == Ressac._NOTICE_MAX
        @test lines[1] == "n1"
        @test isempty(Ressac._drain_notices!())
    end

    @testset "L6 — une pane qui lève au rendu ou à la souris ne ferme pas l'app" begin
        app, frame = _new_app()
        ws = Ressac.current_workspace(app.workspaces)
        Ressac.cmd_split!(app.workspaces, "log", Dict{String,Any}())
        leaf = Ressac._find_leaf_by_id(ws.tree, ws.focused_pane)
        leaf.tabs[leaf.current_tab] = _BoomPane()
        # Rendu : l'erreur se lit dans le journal, la pane voisine est dessinée.
        Tachikoma.view(app, frame)
        @test any(l -> occursin("affichage de la pane « boom »", l) && occursin("rendu cassé", l), app.logs)
        # Souris : idem.
        rects = Ressac._workspace_rects(app, ws, app._last_ws_area)
        r = rects[leaf.id]
        _mouse!(app, r.x + 2, r.y + 2)
        @test any(l -> occursin("[ERROR] souris", l) && occursin("souris cassée", l), app.logs)
        # L'app est toujours pilotable.
        @test app.quit == false
        Tachikoma.view(app, frame)
    end

    @testset "L11/S13 — une règle d'enregistrement, sous verrou" begin
        saved = (copy(Ressac._SYNTH_REGISTRY), copy(Ressac._SYNTH_ALIASES), copy(Ressac._SAMPLE_REGISTRY))
        try
            Ressac._reset_registries!()
            meta(d...) = Dict{String,Any}(d...)
            # Nom libre, puis un autre plugin : le dernier chargé l'emporte, et le dit.
            Ressac.register_synth!(Ressac.SynthEntry(:zz, "autre", meta("description" => "d'abord")))
            @test_logs (:warn, r"synth 'zz' shadowed by plugin 'user-synths' \(previously from 'autre'\)") Ressac.register_synth!(
                Ressac.SynthEntry(:zz, "user-synths", meta("description" => "manifeste")))
            @test Ressac.synth_info(:zz).plugin == "user-synths"
            @test Ressac.synth_info(:zz).metadata["description"] == "manifeste"
            # Le même plugin se ré-enregistre (rechargement) : remplacé, sans bruit.
            @test_logs Ressac.register_synth!(Ressac.SynthEntry(:zz, "user-synths", meta("description" => "relu")))
            @test Ressac.synth_info(:zz).metadata["description"] == "relu"
            # La même règle pour les fiches et les gammes.
            doc(plugin) = Ressac.DocEntry("zzdoc", plugin, Symbol[], Symbol[], String[], String[], "", plugin, "")
            saved_docs = copy(Ressac._DOCS)
            Ressac.register_doc!(doc("core"))
            @test_logs (:warn, r"doc 'zzdoc' shadowed by plugin 'perso' \(previously from 'core'\)") Ressac.register_doc!(doc("perso"))
            @test Ressac.lookup_doc("zzdoc").plugin == "perso"
            empty!(Ressac._DOCS); merge!(Ressac._DOCS, saved_docs)
            sc(v) = Ressac.Scale(:zzscale, [0.0, v], 1200.0)
            @test_logs Ressac.register_scale!(sc(100.0); plugin = "a")
            @test_logs Ressac.register_scale!(sc(150.0); plugin = "a")                    # rechargement
            @test_logs (:warn, r"shadowed by plugin 'b' \(previously from 'a'\)") Ressac.register_scale!(sc(200.0); plugin = "b")
            @test Ressac._SCALES[:zzscale].cents == [0.0, 200.0]
            @test_logs (:warn, r"shadowed by a new definition") Ressac.register_scale!(sc(300.0))
            delete!(Ressac._SCALES, :zzscale); delete!(Ressac._SCALE_OWNERS, :zzscale)
            # T sur le @synth : les params arrivent, le propriétaire reste.
            @test_logs Ressac.SynthDSL._register_dsl_synth!(:zz, (freq = 220, cutoff = 900), nothing)
            e = Ressac.synth_info(:zz)
            @test e.plugin == "user-synths" && e.metadata["description"] == "relu"
            @test e.metadata["params"] == Dict{String,Any}("freq" => 220, "cutoff" => 900)
            @test Ressac._pitch_target(:zz) !== nothing
            # Ré-évaluer avec d'autres params : ils remplacent les anciens.
            Ressac.SynthDSL._register_dsl_synth!(:zz, (cutoff = 1200,), nothing)
            @test Ressac.synth_info(:zz).metadata["params"] == Dict{String,Any}("cutoff" => 1200)
            @test Ressac._pitch_target(:zz) === nothing
            # Ordre inverse — T d'abord, le manifeste ensuite : même résultat.
            Ressac.SynthDSL._register_dsl_synth!(:yy, (freq = 110,), nothing)
            @test_logs Ressac.register_synth!(Ressac.SynthEntry(:yy, "user-synths", meta("description" => "manifeste")))
            e = Ressac.synth_info(:yy)
            @test e.plugin == "user-synths" && e.metadata["description"] == "manifeste"
            @test e.metadata["params"] == Dict{String,Any}("freq" => 110)
            # Samples : `:import` remplace sa propre banque.
            Ressac.register_sample!(Ressac.SampleEntry(:bq, "user-samples", "/a", ["/a/1.wav"], meta()))
            Ressac.register_sample!(Ressac.SampleEntry(:bq, "dirt", "/b", String[], meta()); update = true)
            @test Ressac.sample_info(:bq).bank_path == "/b"
            # Alias.
            @test Ressac.register_synth_alias!(:z, :zz)
            @test Ressac.resolve_synth_name(:z) === :zz
            @test Ressac.synth_alias_for(:zz) === :z
            @test Ressac.unregister_synth_alias!(:z) && !Ressac.unregister_synth_alias!(:z)
            Ressac._reset_registries!()
            @test Ressac.synth_info(:zz) === nothing && isempty(Ressac._SAMPLE_REGISTRY)
        finally
            Ressac._reset_registries!()
            merge!(Ressac._SYNTH_REGISTRY, saved[1]); merge!(Ressac._SYNTH_ALIASES, saved[2])
            merge!(Ressac._SAMPLE_REGISTRY, saved[3])
        end
    end

    @testset "M9 — stop_live! ferme le socket d'envoi" begin
        c = Ressac.OSCClient("127.0.0.1", 57999)
        @test !Ressac._osc_closed(c)
        close(c); close(c)                              # idempotent
        @test Ressac._osc_closed(c)
        @test Ressac.send_osc(c, UInt8[0x00]) === nothing    # avalé, pas d'exception
    end

    @testset "L13 — :pause, :tap, :piano depuis une pane qui n'est pas l'éditeur" begin
        app, frame = _new_app()
        Ressac._active_editor(app).mode = :normal
        Ressac.cmd_split!(app.workspaces, "log", Dict{String,Any}())
        Tachikoma.view(app, frame)
        @test !(Ressac._focused_pane_impl(app) isa Ressac.EditorPane)

        _exec_ex_command!(app, "pause")
        @test app.paused
        _key!(app, 'j')                                 # n'importe quelle touche reprend
        @test !app.paused

        _exec_ex_command!(app, "tap")
        @test app.tap_recording
        _key!(app, ' '); _key!(app, ' ')
        @test length(app.tap_events) == 2
        _key!(app, :escape)
        @test !app.tap_recording && isempty(app.tap_events)

        _exec_ex_command!(app, "piano")
        @test app.piano_active
        _key!(app, :escape)
        @test !app.piano_active
    end

    @testset "L14 — dans une recherche, les touches globales sont du texte" begin
        app, frame = _new_app()
        Ressac._active_editor(app).mode = :normal
        _key!(app, :ctrl, 'p')
        @test app.modal === :palette && Ressac._text_entry_active(app)
        n_logs = length(app.logs)
        for c in "é!:"; _key!(app, c); end
        @test Tachikoma.text(app.palette.input) == "é!:"
        @test !any(l -> occursin("PANIC", l), app.logs[n_logs+1:end])
        @test !Ressac.is_active(app.command_line)
        _key!(app, :ctrl, 'w')
        @test !Ressac._PANE_MODE.active
        _key!(app, :escape)
        @test app.modal === :none && !Ressac._text_entry_active(app)
        # Hors saisie, `!` reste le PANIC.
        _key!(app, '!')
        @test any(l -> occursin("PANIC", l), app.logs)
    end
end
