include(joinpath(@__DIR__, "helpers.jl"))
# L'explorateur ouvert sur un slot — étape E5.7.

_es_sounds(app, slot) = Ressac._sounds_of(Ressac.pattern_get(app.scheduler, slot))

@testset "explorer sur un slot" begin

    @testset "_with_sound : le rythme, les notes et les effets restent, le son change" begin
        p = :wob |> n("0 3 7") |> gain(0.5)
        q = Ressac._with_sound(p, :ga_slot2)
        a = p(0 // 1, 1 // 1); b = q(0 // 1, 1 // 1)
        @test length(b) == length(a) == 3
        @test all(ev -> ev.value[:s] === :ga_slot2 && ev.value[:gain] == 0.5, b)
        @test [ev.value[:n] for ev in b] == [ev.value[:n] for ev in a]
        @test [(ev.start, ev.stop) for ev in b] == [(ev.start, ev.stop) for ev in a]
        # Un pattern de sons nus (p"bd cp") aussi.
        @test all(ev -> ev.value === :x, Ressac._with_sound(p"bd cp", :x)(0 // 1, 1 // 1))
        @test Ressac._sounds_of(p"bd:3 cp bd") == ["bd", "cp"]
    end

    @testset "gx sur une ligne qui joue : le candidat du curseur joue dans le pattern" begin
        _with_live_app() do app, frame
            _set_buffer!(app, "@d1 p\"bd bd\"\n@d2 :wob |> n(\"0 3 7\")", row = 2)
            _key!(app, 'E')
            original = Ressac.pattern_get(app.scheduler, :d2)
            _type!(app, "gx")
            @test app.volet === :explorer && app.explore_slot[1] === :d2
            Tachikoma.view(app, frame)
            p = Ressac._find_pane(app, Ressac.SynthExplorerPane)
            @test _es_sounds(app, :d2) == [String(p.audition.slot_names[p.focus])]
            @test length(Ressac.pattern_get(app.scheduler, :d2)(0 // 1, 1 // 1)) == 3     # mêmes notes
            @test _es_sounds(app, :d1) == ["bd"]                                    # les autres slots ne bougent pas
            # Un autre candidat : c'est lui qui joue.
            p.focus = 3
            Tachikoma.view(app, frame)
            @test _es_sounds(app, :d2) == [String(p.audition.slot_names[3])]
            # Le titre dit pour quoi on cherche.
            buf = frame.buffer
            screen = join((join(buf.content[Tachikoma.buf_index(buf, x, y)].char for x in 1:buf.area.width) for y in 1:3), "\n")
            @test occursin("un autre son pour d2", screen)
            # Sortir sans adopter rend le son d'origine.
            _exec_ex_command!(app, "back")
            Tachikoma.view(app, frame)
            @test app.explore_slot === nothing
            @test Ressac.pattern_get(app.scheduler, :d2) === original
        end
    end

    @testset "Entrée adopte : le son est rangé, la ligne réécrite et réévaluée" begin
        _with_live_app() do app, frame
            _set_buffer!(app, "@d1 p\"bd bd\"\n@d2 :wob |> n(\"0 3 7\")", row = 2)
            _key!(app, 'E')
            _type!(app, "gx")
            Tachikoma.view(app, frame)
            _key!(app, :enter)
            @test app.volet === :fiche && app.explore_slot === nothing
            text = _buffer_text(app)
            @test occursin("@d2 :trouve |> n(\"0 3 7\")", text) && occursin("@d1 p\"bd bd\"", text)
            path = joinpath(pwd(), "plugins", "user-synths", "trouve.jl")
            @test isfile(path) && occursin("@synth :trouve", read(path, String))
            @test Ressac.synth_info(:trouve) !== nothing
            @test _es_sounds(app, :d2) == ["trouve"]
            @test Ressac._slot_line(app, :d2).state === :playing
            # Une seconde adoption prend un autre nom.
            Ressac._patterns_editor(app).cursor_row = 2
            _type!(app, "gx"); Tachikoma.view(app, frame); _key!(app, :enter)
            @test occursin("@d2 :trouve2 |>", _buffer_text(app))
        end
    end

    @testset "gx hors d'une ligne qui joue : l'explorateur s'ouvre, sans rien remplacer" begin
        _with_live_app() do app, frame
            _set_buffer!(app, "@d1 p\"bd bd\"")
            _type!(app, "gx")                                                     # rien n'a été évalué
            @test app.volet === :explorer && app.explore_slot === nothing
            Tachikoma.view(app, frame)
            @test Ressac.pattern_get(app.scheduler, :d1) === nothing
            _key!(app, :enter)                                                    # Entrée n'adopte rien
            @test app.volet === :explorer
        end
    end
end
