include(joinpath(@__DIR__, "helpers.jl"))
# L'état de chaque ligne @dN — étape E1 de l'écran unique.
#
# Ce que l'écran dira de chaque ligne (joue, muet, modifié, en erreur, à
# l'arrêt) se décide ici, sans rien dessiner.

_states(app) = [(l.slot, l.state) for l in Ressac._slot_lines(app)]
_state(app, slot) = Ressac._slot_line(app, slot).state

@testset "état des lignes @dN" begin

    @testset "les blocs du texte" begin
        lines = split("""
            cps!(0.5)
            basse = p"c e g"
            @d1 p"bd bd"
            # @d2 p"cp"
            @d3 p"hh*8"
              |> gain(0.4)
            @d4 stack([p"a",
                       p"b"])
            """, '\n')
        (blocks, prelude) = Ressac._scan_slot_blocks(lines)
        @test [(b.slot, b.row, b.last_row, b.commented) for b in blocks] ==
              [(:d1, 3, 3, false), (:d2, 4, 4, true), (:d3, 5, 6, false), (:d4, 7, 8, false)]
        @test blocks[3].src == "@d3 p\"hh*8\" |> gain(0.4)"          # le |> est recollé
        @test prelude == ["cps!(0.5)", "basse = p\"c e g\""]
        # Un slot écrit deux fois : la définition la plus basse compte.
        (twice, _) = Ressac._scan_slot_blocks(["@d1 p\"a\"", "@d1 p\"b\""])
        @test Ressac._live_blocks(twice)[:d1].row == 2
    end

    @testset "la règle d'état (pure)" begin
        b = Ressac.SlotBlock(:d1, 1, 1, "@d1 p\"bd\"", false)
        st(; live = true, playing = false, cut = false, evaluated = nothing, error = nothing, block = b) =
            Ressac._slot_state(block, live; playing, cut, evaluated, error)
        @test st() === :idle                                            # jamais évalué
        @test st(playing = true, evaluated = b.src) === :playing
        @test st(playing = true) === :playing                           # posé sans passer par le texte (:tap…)
        @test st(playing = true, evaluated = "@d1 p\"sn\"") === :modified
        @test st(playing = true, cut = true, evaluated = b.src) === :muted
        @test st(block = Ressac.SlotBlock(:d1, 1, 1, "# @d1 p\"bd\"", true), playing = true) === :muted
        @test st(live = false, playing = true, evaluated = b.src) === :idle   # masqué par un bloc plus bas
        err = Ressac.SlotError(b.src, "boum", true)
        @test st(playing = true, evaluated = "@d1 p\"sn\"", error = err) === :error
        # L'erreur porte sur un texte : dès qu'on le change, elle n'est plus d'actualité.
        @test st(playing = true, evaluated = "@d1 p\"sn\"", error = Ressac.SlotError("@d1 p\"b", "x", true)) === :modified
    end

    @testset "la valeur de note suit la densité" begin
        @test Ressac._note_value.([0, 1, 2, 4, 8, 16, 32, 64]) == [0, 1, 2, 3, 4, 5, 6, 6]
        @test Ressac._note_value.([3, 6, 12]) == [3, 4, 5]             # la puissance de deux la plus proche
    end

    @testset "évaluer, modifier, réévaluer" begin
        _with_live_app() do app, _
            _set_buffer!(app, "@d1 p\"bd bd\"\n@d2 p\"cp\"")
            @test _states(app) == [(:d1, :idle), (:d2, :idle)]              # rien n'a été lancé
            _key!(app, 'E')
            @test _states(app) == [(:d1, :playing), (:d2, :playing)]
            # On change le texte de d1 sans évaluer : ce qu'on lit n'est plus ce qu'on entend.
            _set_buffer!(app, "@d1 p\"bd sn\"\n@d2 p\"cp\"")
            @test _states(app) == [(:d1, :modified), (:d2, :playing)]
            _key!(app, 'e')
            @test _states(app) == [(:d1, :playing), (:d2, :playing)]
            # Revenir au texte évalué efface « modifié » sans rien évaluer.
            _set_buffer!(app, "@d1 p\"bd bd bd\"\n@d2 p\"cp\"")
            @test _state(app, :d1) === :modified
            _set_buffer!(app, "@d1 p\"bd sn\"\n@d2 p\"cp\"")
            @test _state(app, :d1) === :playing
        end
    end

    @testset "une erreur reste sous sa ligne jusqu'à correction" begin
        _with_live_app() do app, _
            _set_buffer!(app, "@d1 p\"bd bd\"")
            _key!(app, 'E')
            _set_buffer!(app, "@d1 p\"bd bd\" |> pas_une_fonction(3)")
            _key!(app, 'e')
            l = Ressac._slot_line(app, :d1)
            @test l.state === :error
            @test l.error.kept                                              # l'ancien d1 joue toujours
            @test occursin("pas_une_fonction", l.error.message)
            @test Ressac.pattern_get(app.scheduler, :d1) !== nothing
            # Un slot qui ne jouait pas : l'erreur le dit aussi.
            _set_buffer!(app, "@d1 p\"bd bd\" |> pas_une_fonction(3)\n@d2 nexiste_pas", row = 2)
            _key!(app, 'e')
            @test !Ressac._slot_line(app, :d2).error.kept
            # Corriger et réévaluer efface l'erreur.
            _set_buffer!(app, "@d1 p\"bd sn\"")
            @test _state(app, :d1) === :modified                           # le texte fautif n'est plus là
            _key!(app, 'e')
            @test _state(app, :d1) === :playing
            @test !haskey(app.slot_errors, :d1)
        end
    end

    @testset "E consigne chaque slot, réussi ou raté" begin
        _with_live_app() do app, _
            _set_buffer!(app, "@d1 p\"bd\"\n@d2 p\"cp\" |> pas_une_fonction(1)\n@d3 p\"hh\"")
            _key!(app, 'E')
            @test _states(app) == [(:d1, :playing), (:d2, :error), (:d3, :playing)]
        end
    end

    @testset "muet : ligne commentée, ou coupée au mixer" begin
        _with_live_app() do app, _
            _set_buffer!(app, "@d1 p\"bd\"\n@d2 p\"cp\"")
            _key!(app, 'E')
            _key!(app, 'm')                                                 # commente la ligne 1
            @test startswith(_buffer_text(app), "# @d1")
            @test _states(app) == [(:d1, :muted), (:d2, :playing)]
            _key!(app, 'm')
            @test _state(app, :d1) === :playing
            Ressac._mute_pattern_slot!(app, :d2)
            @test _state(app, :d2) === :muted
            Ressac._unmute_pattern_slot!(app, :d2)
            @test _state(app, :d2) === :playing
        end
    end

    @testset "un pattern qui lève en jouant : l'erreur arrive sur sa ligne" begin
        _with_live_app() do app, _
            _set_buffer!(app, "@d1 p\"bd\"")
            _key!(app, 'E')
            Ressac.unset_pattern!(app.scheduler, :d1)                       # ce que fait le scheduler en le retirant
            Ressac._notify_fault!(:d1, "DomainError")
            l = Ressac._slot_line(app, :d1)
            @test l.state === :error
            @test l.error.message == "DomainError" && !l.error.kept
        end
    end

    @testset "tout arrêter remet les lignes à l'arrêt" begin
        _with_live_app() do app, _
            _set_buffer!(app, "@d1 p\"bd\"")
            _key!(app, 'E')
            _key!(app, ',')
            @test _states(app) == [(:d1, :idle)]
        end
    end

    @testset "densité : les coups du cycle, d'où la note" begin
        _with_live_app() do app, _
            _set_buffer!(app, "@d1 p\"bd bd bd bd\"\n@d2 p\"hh*16\"\n@d3 p\"cp\"")
            _key!(app, 'E')
            ls = Ressac._slot_lines(app)
            @test [l.onsets for l in ls] == [4, 16, 1]
            @test Ressac._note_value.([l.onsets for l in ls]) == [3, 5, 1]
        end
    end
end

@testset "la fiche dit ce que fait la ligne du curseur" begin
    _with_live_app() do app, frame
        _set_buffer!(app, "cps!(0.5)\n@d1 :pad |> n(\"0 3 7 12\")\n@d2 p\"bd bd\"")
        _key!(app, 'E')
        ed = Ressac._patterns_editor(app)
        ed.cursor_row = 1
        @test isempty(Ressac._cursor_slot_summary(app))                    # hors d'un bloc @dN
        ed.cursor_row = 2
        s = Ressac._cursor_slot_summary(app)
        @test s[1][1] == "d1 — joue · 4 coups par cycle"
        @test ("notes : 0 3 7 12", :text_dim) in s                         # les notes exactes, que la piste ne dit pas
        ed.cursor_row = 3
        @test !any(t -> startswith(t[1], "notes"), Ressac._cursor_slot_summary(app))   # pas de hauteurs : rien
        # Une erreur : la cause en entier, et ce qui continue.
        _set_buffer!(app, "cps!(0.5)\n@d1 :pad |> n(\"0 3 7 12\")\n@d2 p\"bd bd\" |> nexiste_pas(1)", row = 3)
        _key!(app, 'e')
        s = Ressac._cursor_slot_summary(app)
        @test s[1] == ("d2 — en erreur", :error)
        @test occursin("nexiste_pas", s[2][1]) && s[3][1] == "l'ancien pattern joue toujours"
        # …et elle est à l'écran, dans la colonne de droite.
        Ressac._open_volet!(app, :fiche; focus = false)
        Tachikoma.reset!(frame.buffer); Tachikoma.view(app, frame)
        buf = frame.buffer
        screen = join((join(buf.content[Tachikoma.buf_index(buf, x, y)].char for x in 1:buf.area.width) for y in 1:buf.area.height), "\n")
        @test occursin("d2 — en erreur", screen)
    end
end
