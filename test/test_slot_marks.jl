include(joinpath(@__DIR__, "helpers.jl"))
# Ce que l'écran dit de chaque ligne @dN — étape E2 (marge, fond, piste, erreur).

# La ligne d'écran qui porte le texte `needle`, et la cellule de son signe.
function _sm_draw(app, frame)
    Tachikoma.reset!(frame.buffer)
    Tachikoma.view(app, frame)
    return frame.buffer
end
_sm_rows(buf) = [join(buf.content[Tachikoma.buf_index(buf, x, y)].char for x in 1:buf.area.width) for y in 1:buf.area.height]
function _sm_row(buf, needle)
    y = findfirst(r -> occursin(needle, r), _sm_rows(buf))
    y === nothing && error("« $needle » n'est pas à l'écran")
    return y
end
_sm_cell(buf, x, y) = buf.content[Tachikoma.buf_index(buf, x, y)]
# Le signe : la cellule deux colonnes avant le numéro de ligne.
function _sm_sign(buf, needle)
    y = _sm_row(buf, needle)
    row = _sm_rows(buf)[y]
    x = findfirst(c -> c == '│', collect(row))                # le cadre gauche de la pane
    return _sm_cell(buf, x + 1, y).char
end
_sm_bg(buf, needle; dx = 3) = (y = _sm_row(buf, needle);
    x = findfirst(c -> c == '│', collect(_sm_rows(buf)[y])); _sm_cell(buf, x + dx, y).style.bg)

function _sm_with(f, marks::Symbol = :transport)
    cfg = Ressac.ressac_config()
    old = (cfg.marks, cfg.calm)
    cfg.marks = marks
    try
        _with_live_app(f)
    finally
        (cfg.marks, cfg.calm) = old
    end
end

@testset "marques de ligne" begin

    @testset "les familles de signes" begin
        for (name, set) in Ressac._MARK_SETS
            @test all(c -> textwidth(c) <= 1, (set.notes..., set.rests..., set.modified, set.error, set.held, set.offgrid))
        end
        s = Ressac._MARK_SETS[:solfege]
        line(state; held = false, offgrid = false, onsets = 4) =
            Ressac.SlotLine(:d1, 1, 1, state, held, offgrid, onsets, nothing)
        # La valeur de note suit la densité.
        @test [Ressac._mark_char(line(:playing; onsets = n), s) for n in (1, 2, 4, 8, 16, 32)] == collect(s.notes)
        @test Ressac._mark_char(line(:playing; held = true), s) == s.held
        @test Ressac._mark_char(line(:playing; offgrid = true), s) == s.offgrid
        @test Ressac._mark_char(line(:modified), s) == s.modified
        @test Ressac._mark_char(line(:muted), s) == s.rests[3]
        @test Ressac._mark_char(line(:error), s) == s.error
        @test Ressac._mark_char(line(:idle), s) === nothing          # une ligne à l'arrêt ne porte rien
    end

    @testset "la piste d'un cycle" begin
        ev(start, v) = Ressac.Event(start, start + 1 // 8, v)
        cells = Ressac._lane_cells([ev(3 // 1, :bd), ev(13 // 4, :bd), ev(7 // 2, :bd), ev(15 // 4, :bd)], 3, 16)
        @test String(cells) == "█   █   █   █   "
        # Des hauteurs : la taille du bloc dit la hauteur, grave en bas.
        pitched = Ressac._lane_cells([ev(0 // 1, Dict(:n => 0)), ev(1 // 2, Dict(:n => 12))], 0, 8)
        @test pitched[1] == '▁' && pitched[5] == '█'
        # Une seule hauteur : pas d'échelle à montrer, bloc plein.
        @test Ressac._lane_cells([ev(0 // 1, Dict(:n => 5))], 0, 4)[1] == '█'
        @test all(==(' '), Ressac._lane_cells(Ressac.Event[], 0, 8))
        # Large, étroite, ou rien selon la place à droite du texte.
        @test Ressac._lane_width(20, 100) == 48
        @test Ressac._lane_width(60, 100) == 24
        @test Ressac._lane_width(90, 100) == 0
    end

    @testset "le signe est dans la marge, le texte ne bouge pas" begin
        _sm_with() do app, frame
            _set_buffer!(app, "@d1 p\"bd bd\"\n# @d2 p\"cp\"\n@d3 p\"hh*8\"")
            buf = _sm_draw(app, frame)
            @test _sm_sign(buf, "@d1") == ' '                        # rien n'est lancé
            _key!(app, 'E')
            buf = _sm_draw(app, frame)
            @test _sm_sign(buf, "@d1") == '▶'
            @test _sm_sign(buf, "@d2") == '‖'                        # commenté = muet
            @test occursin("1│@d1 p\"bd bd\"", _sm_rows(buf)[_sm_row(buf, "@d1")])
            _set_buffer!(app, "@d1 p\"bd sn\"\n# @d2 p\"cp\"\n@d3 p\"hh*8\"")
            @test _sm_sign(_sm_draw(app, frame), "@d1") == '✎'       # modifié, pas évalué
        end
    end

    @testset "en solfège, la note dit la vitesse" begin
        _sm_with(:solfege) do app, frame
            _set_buffer!(app, "@d1 p\"bd bd bd bd\"\n@d2 p\"hh*16\"\n@d3 p\"cp\"")
            _key!(app, 'E')
            buf = _sm_draw(app, frame)
            s = Ressac._MARK_SETS[:solfege]
            @test _sm_sign(buf, "@d1") == s.notes[3]                 # noire
            @test _sm_sign(buf, "@d2") == s.notes[5]                 # double croche
            @test _sm_sign(buf, "@d3") == s.notes[1]                 # ronde
        end
    end

    @testset "la piste est sur la rangée de sa ligne" begin
        _sm_with() do app, frame
            _set_buffer!(app, "@d1 p\"bd bd bd bd\"\n@d2 p\"hh*8\"\n  |> gain(0.4)")
            _key!(app, 'E')
            rows = _sm_rows(_sm_draw(app, frame))
            @test count(==('█'), rows[_sm_row(frame.buffer, "@d1")]) == 4
            @test count(==('█'), rows[_sm_row(frame.buffer, "@d2")]) == 8   # la première ligne du bloc
            @test !occursin('█', rows[_sm_row(frame.buffer, "|> gain")])
            # :pistes les cache.
            _exec_ex_command!(app, "pistes")
            rows = _sm_rows(_sm_draw(app, frame))
            @test !occursin('█', rows[_sm_row(frame.buffer, "@d1")])
        end
    end

    @testset "la piste montre ce que le slot joue, pas ce qui est écrit" begin
        _sm_with() do app, frame
            # Les notes viennent d'une fonction : le texte ne les montre pas, la piste si.
            _set_buffer!(app, "@d1 :pad |> n(fib(5))\n@d9 p\"cp*4\"")
            Ressac.set_pattern!(app.scheduler, :d1, :pad |> n(fib(5)))
            buf = _sm_draw(app, frame)
            row = _sm_rows(buf)[_sm_row(buf, "@d1")]
            @test count(c -> c in Ressac._LANE_LEVELS, row) == 5         # 1 1 2 3 5
            @test occursin('▁', row) && occursin('█', row)               # du plus grave au plus aigu
            # Un slot écrit mais pas lancé n'a pas de piste.
            @test !any(c -> c in Ressac._LANE_LEVELS, _sm_rows(buf)[_sm_row(buf, "@d9")])
        end
    end

    @testset "une ligne trop longue n'a pas de piste" begin
        _sm_with() do app, frame
            _set_buffer!(app, "@d1 p\"bd bd bd bd\" |> gain(0.5) |> lpf(2000) |> room(0.3) |> pan(0.5) |> hpf(40) |> delay(0.2) |> crush(8)")
            _key!(app, 'E')
            rows = _sm_rows(_sm_draw(app, frame))
            @test !occursin('█', rows[_sm_row(frame.buffer, "@d1")])
        end
    end

    @testset "l'erreur est écrite sur sa ligne, et dit ce qui continue" begin
        _sm_with() do app, frame
            _set_buffer!(app, "@d1 p\"bd\"")
            _key!(app, 'E')
            _set_buffer!(app, "@d1 p\"bd\" |> nexiste_pas(1)")
            _key!(app, 'e')
            buf = _sm_draw(app, frame)
            row = _sm_rows(buf)[_sm_row(buf, "@d1")]
            @test _sm_sign(buf, "@d1") == '✗'
            @test occursin("← « nexiste_pas » n'existe pas", row)
            # Le message entier, sans la coupe due à la largeur de l'écran.
            @test endswith(Ressac._error_text(Ressac._slot_line(app, :d1).error), "l'ancien joue toujours")
            @test Ressac._fit("abcdef", 4) == "abc…"
        end
    end

    @testset "le fond : allumé au coup, stable quand l'écran est calme" begin
        _sm_with() do app, frame
            _set_buffer!(app, "@d1 p\"bd\"\n@d2 p\"cp\"")
            buf = _sm_draw(app, frame)
            @test _sm_bg(buf, "@d1") isa Tachikoma.NoColor           # à l'arrêt : pas de fond
            _key!(app, 'E')
            lock(app.scheduler.lock) do
                app.scheduler.last_fired_at[:d1] = time()            # d1 vient de frapper
                app.scheduler.last_fired_at[:d2] = time() - 5.0      # d2 il y a longtemps
            end
            buf = _sm_draw(app, frame)
            hot, cold = _sm_bg(buf, "@d1"), _sm_bg(buf, "@d2")
            @test hot isa Tachikoma.ColorRGB && cold isa Tachikoma.ColorRGB
            @test hot != cold
            # Le texte garde sa couleur : seul le fond change.
            y = _sm_row(buf, "@d1")
            x = findfirst(==('@'), collect(_sm_rows(buf)[y]))
            @test _sm_cell(buf, x, y).char == '@'
            # :calme — plus rien ne dépend de l'instant du coup.
            _exec_ex_command!(app, "calme")
            calm_hot = _sm_bg(_sm_draw(app, frame), "@d1")
            lock(() -> (app.scheduler.last_fired_at[:d1] = time() - 5.0), app.scheduler.lock)
            @test _sm_bg(_sm_draw(app, frame), "@d1") == calm_hot
            @test calm_hot != hot
        end
    end

    @testset "sans police de solfège, :auto prend les signes de lecteur" begin
        cfg = Ressac.ressac_config(); old = cfg.marks; keep = Ressac._SOLFEGE_FONT_OK[]
        try
            cfg.marks = :auto
            Ressac._SOLFEGE_FONT_OK[] = false
            @test Ressac._mark_set() === Ressac._MARK_SETS[:transport]
            Ressac._SOLFEGE_FONT_OK[] = true
            @test Ressac._mark_set() === Ressac._MARK_SETS[:solfege]
            cfg.marks = :formes
            @test Ressac._mark_set() === Ressac._MARK_SETS[:formes]
        finally
            cfg.marks = old; Ressac._SOLFEGE_FONT_OK[] = keep
        end
    end
end
