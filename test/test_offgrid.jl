include(joinpath(@__DIR__, "helpers.jl"))
# Hors de la grille — étape E6 : Entrée = maintenant, frappes, la boucle.

_og_starts(p, a, b) = [ev.start for ev in p(Rational{Int64}(a), Rational{Int64}(b))]

@testset "hors grille" begin

    @testset "frappes : des instants exacts, sur une longueur libre" begin
        p = :bd |> frappes(0, 0.4, 1.1; cycles = 1.5)
        evs = p(0 // 1, 3 // 1)
        @test [ev.start for ev in evs] == [0 // 1, 2 // 5, 11 // 10, 3 // 2, 19 // 10, 13 // 5]   # deux tours de 1,5 cycle
        @test [ev.stop for ev in evs][1:3] == [2 // 5, 11 // 10, 3 // 2]          # chaque frappe dure jusqu'à la suivante
        @test all(ev -> ev.value === :bd, evs)
        # une fenêtre qui coupe la boucle ne rend que ce qui y commence
        @test _og_starts(p, 1, 2) == [11 // 10, 3 // 2, 19 // 10]
        @test isempty(p(1 // 5, 2 // 5))
        # les frappes prennent tour à tour les valeurs du pattern
        q = p"bd sn" |> frappes(0, 0.25, 0.5; cycles = 1)
        @test [ev.value for ev in q(0 // 1, 1 // 1)] == [:bd, :sn, :bd]
        # forme directe, instants dans le désordre ou hors de la boucle, aucun instant
        @test _og_starts(frappes(p"hh", 0.75, 0.25, 1.25; cycles = 1), 0, 1) == [1 // 4, 3 // 4]
        @test isempty((:bd |> frappes(; cycles = 2))(0 // 1, 4 // 1))
        @test_throws ArgumentError frappes(p"bd", 0; cycles = 0)
        # les contrôles en aval s'appliquent comme sur tout pattern
        r = :bd |> frappes(0, 0.5; cycles = 1) |> gain(0.5)
        @test all(ev -> ev.value[:gain] == 0.5, r(0 // 1, 1 // 1))
    end

    @testset "play_now! : ce qui tombe avant le curseur du scheduler part tout de suite" begin
        osc = MockOSCClient()
        s = Ressac.Scheduler(osc; cps = 1.0)
        s.t_start = time() - 10.0
        s.last_end_cycles = 10.05                       # la boucle a déjà couvert jusqu'ici
        n0 = length(osc.sent)
        Ressac.play_now!(s, :d1, late(10, p"bd"), 10.0)
        @test length(osc.sent) == n0 + 1                # la note posée « maintenant » sonne
        @test Ressac.pattern_get(s, :d1) !== nothing
        # rien avant le curseur : rien n'est envoyé deux fois
        Ressac.play_now!(s, :d2, late(10.5, p"bd"), 10.0)
        @test length(osc.sent) == n0 + 1
        # un pattern en attente sur le slot est remplacé, pas ajouté
        Ressac.schedule_pattern!(s, :d3, p"hh", 12 // 1)
        Ressac.play_now!(s, :d3, late(10, p"bd"), 10.2)
        @test !haskey(s.pending, :d3)
        # un instant périmé ne fait pas rejouer le passé : au plus ce que la boucle rattrape
        n1 = length(osc.sent)
        Ressac.play_now!(s, :d4, p"bd*4", -1.0e6)
        @test length(osc.sent) - n1 <= 5
    end

    @testset "Entrée : la ligne part de la frappe ; e la recale" begin
        _with_live_app() do app, frame
            sched = app.scheduler
            sched.t_start = time() - 3.3 / sched.cps    # on est au cycle 3,3
            _set_buffer!(app, "@d1 p\"bd sn\"\nx = 3")
            sched.last_end_cycles = (time() - sched.t_start) * sched.cps + 0.5   # le curseur du scheduler, devant « maintenant »
            n0 = length(sched.osc.sent)
            _key!(app, :enter)
            pat = Ressac.pattern_get(sched, :d1)
            starts = _og_starts(pat, 3, 5)
            @test 33 // 10 <= starts[1] < 34 // 10                      # le cycle 0 commence à la frappe
            @test starts[2] - starts[1] == 1 // 2                       # le motif, lui, n'a pas bougé
            @test length(sched.osc.sent) > n0                           # et sa première note est partie
            @test haskey(app.slot_offgrid, :d1) && Ressac._slot_line(app, :d1).offgrid
            @test any(l -> occursin("d1 lancé maintenant, hors de la grille", l), app.logs)
            @test any(l -> occursin("hors de la grille", l[1]), Ressac._slot_summary(app, Ressac._slot_line(app, :d1)))
            # e : de nouveau sur la grille
            _key!(app, 'e')
            @test !haskey(app.slot_offgrid, :d1)
            @test _og_starts(Ressac.pattern_get(sched, :d1), 3, 4) == [3 // 1, 7 // 2]
            # m / m sur un slot lancé par Entrée : il revient calé sur la frappe
            # d'ORIGINE (cycle 3,3), ni sur la grille ni sur l'instant du démute.
            _key!(app, :enter); @test haskey(app.slot_offgrid, :d1)
            before = app.slot_offgrid[:d1]
            _key!(app, 'm')
            @test Ressac.pattern_get(sched, :d1) === nothing
            sched.t_start = time() - 6.3 / sched.cps
            sched.last_end_cycles = (time() - sched.t_start) * sched.cps + 0.5
            _key!(app, 'm')
            again = _og_starts(Ressac.pattern_get(sched, :d1), 6, 8)
            origin = app.slot_offgrid[:d1]
            @test origin == before                                      # la frappe d'origine, pas celle du démute
            @test !isempty(again) && all(t -> isinteger((t - origin) * 2), again)   # « bd sn » : des demi-cycles depuis l'origine
            _key!(app, 'e')
            # Entrée sur une ligne qui n'est pas un slot : comme e
            Ressac._patterns_editor(app).cursor_row = 2
            _key!(app, :enter)
            @test Core.eval(Main, :x) == 3 && occursin("éval ⇒ 3", app.logs[end])
            # E recale tout
            Ressac._patterns_editor(app).cursor_row = 1
            _key!(app, :enter); @test haskey(app.slot_offgrid, :d1)
            _key!(app, 'E'); @test isempty(app.slot_offgrid)
        end
    end

    @testset "la boucle : Espace o, des frappes, o — écrite telle que jouée, calée sur l'ouverture" begin
        old = Ressac._LOOP_CLOCK[]
        now = Ref(1000.0)
        Ressac._LOOP_CLOCK[] = () -> now[]
        try
            _with_live_app() do app, frame
                sched = app.scheduler
                Ressac.set_cps!(sched, 0.5)
                sched.t_start = 990.0                       # à l'ouverture : cycle 5
                sched.last_end_cycles = 5.0
                _set_buffer!(app, "@d1 :bd")
                _type!(app, " o")
                @test app.loop !== nothing && app.loop.slot === :d1 && app.loop.expr == ":bd"
                Tachikoma.view(app, frame)
                n0 = length(sched.osc.sent)
                now[] = 1000.5; _key!(app, ' ')
                @test length(sched.osc.sent) == n0 + 1      # la frappe s'entend
                now[] = 1001.0; _key!(app, ' ')
                _key!(app, 'j')                             # les autres touches ne font rien pendant la boucle
                @test app.loop !== nothing && length(app.loop.hits) == 2
                now[] = 1003.0; _key!(app, 'o')
                @test app.loop === nothing
                @test _buffer_text(app) == "@d1 :bd |> frappes(0.25, 0.5; cycles = 1.5)"
                pat = Ressac.pattern_get(sched, :d1)
                @test _og_starts(pat, 5, 8) == [21 // 4, 11 // 2, 27 // 4, 7 // 1]   # 5 + 0,25 · 5 + 0,5 · puis un tour plus loin
                @test haskey(app.slot_offgrid, :d1)
                @test Ressac._slot_line(app, :d1).state === :playing

                # ré-enregistrer sur la même ligne remplace la boucle
                now[] = 1010.0; _type!(app, " o")
                @test app.loop.expr == ":bd"
                now[] = 1010.2; _key!(app, ' ')
                now[] = 1011.0; _key!(app, :enter)          # Entrée ferme aussi
                @test _buffer_text(app) == "@d1 :bd |> frappes(0.1; cycles = 0.5)"

                # Échap annule ; fermer sans frappe n'écrit rien
                _type!(app, " o"); _key!(app, ' '); _key!(app, :escape)
                @test app.loop === nothing && _buffer_text(app) == "@d1 :bd |> frappes(0.1; cycles = 0.5)"
                _type!(app, " o"); _key!(app, 'o')
                @test app.loop === nothing && occursin("sans frappe", app.logs[end])
            end
        finally
            Ressac._LOOP_CLOCK[] = old
        end
    end

    @testset "la boucle sur un bloc de plusieurs lignes, et sur le nom d'un son" begin
        old = Ressac._LOOP_CLOCK[]
        now = Ref(500.0)
        Ressac._LOOP_CLOCK[] = () -> now[]
        try
            _with_live_app() do app, frame
                sched = app.scheduler
                Ressac.set_cps!(sched, 1.0); sched.t_start = 500.0; sched.last_end_cycles = 0.0
                Ressac.register_synth!(Ressac.SynthEntry(:hh, "test", Dict{String,Any}()); update = true)
                _set_buffer!(app, "@d2 p\"bd sn\"\n  |> gain(0.8)\n\n# hh\n# inconnu_au_bataillon", row = 2)
                _type!(app, " o")
                @test app.loop !== nothing && length(app.loop.values) == 2      # bd puis sn, tour à tour
                now[] = 500.5; _key!(app, ' ')
                now[] = 502.0; _key!(app, 'o')
                @test startswith(_buffer_text(app), "@d2 p\"bd sn\"\n  |> gain(0.8)\n  |> frappes(0.5; cycles = 2)\n\n# hh\n")
                @test Ressac._slot_line(app, :d2).state === :playing
                # sur un mot : une ligne neuve, sur un slot libre
                Ressac._patterns_editor(app).cursor_row = 5; Ressac._patterns_editor(app).cursor_col = 2
                now[] = 510.0; _type!(app, " o")
                @test app.loop !== nothing && app.loop.slot === :d1 && app.loop.expr == ":hh"
                now[] = 510.25; _key!(app, ' ')
                now[] = 511.0; _key!(app, 'o')
                @test occursin("# hh\n@d1 :hh |> frappes(0.25; cycles = 1)\n", _buffer_text(app))
                # sur un mot qui n'est pas un son, ou nulle part : la boucle ne s'ouvre pas
                Ressac._patterns_editor(app).cursor_row = 7; Ressac._patterns_editor(app).cursor_col = 4
                _type!(app, " o")
                @test app.loop === nothing && occursin("pose le curseur", app.logs[end])
                Ressac._patterns_editor(app).cursor_row = 4
                _type!(app, " o")
                @test app.loop === nothing && occursin("pose le curseur", app.logs[end])
            end
        finally
            Ressac._LOOP_CLOCK[] = old
        end
    end
end
