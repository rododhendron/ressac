include(joinpath(@__DIR__, "helpers.jl"))
# Le langage visuel (ui_style.jl) : les fonds, la dernière passe, les
# fenêtres qui recouvrent et éteignent, la grille du cycle.

_ui_draw(app, frame) = (Tachikoma.reset!(frame.buffer); Tachikoma.view(app, frame); frame.buffer)
_ui_cellat(buf, x, y) = buf.content[Tachikoma.buf_index(buf, x, y)]
_ui_rows(buf) = [join(_ui_cellat(buf, x, y).char for x in 1:buf.area.width) for y in 1:buf.area.height]
function _ui_find(buf, needle)
    for (y, r) in enumerate(_ui_rows(buf))
        i = findfirst(needle, r)
        i === nothing || return (length(r[1:prevind(r, i.start)]) + 1, y)
    end
    error("« $needle » n'est pas à l'écran")
end

@testset "langage visuel" begin

    @testset "la palette : celle de Ressac, ou déduite du thème" begin
        Ressac._init_custom_themes!()
        old = Tachikoma.theme()
        try
            @test Ressac._apply_theme!(:ressac)
            @test Ressac._ui() === Ressac._RESSAC_PALETTE
            # Les codes 256 du thème sont tous dans la table des couleurs exactes.
            th = Tachikoma.theme()
            @test all(f -> haskey(Ressac._RESSAC_REMAP, getfield(th, f).code), fieldnames(typeof(th))[2:end])
            @test Ressac._apply_theme!(:kokaku)
            p = Ressac._ui()
            @test p.name == "kokaku" && p.bg == Tachikoma.to_rgb(Tachikoma.theme().bg)
            @test p.s1 != p.bg && p.s2 != p.s1 && p.s3 != p.s2      # trois surfaces distinctes
        finally
            Tachikoma.set_theme!(old)
        end
    end

    @testset "la dernière passe : un fond partout, les couleurs exactes" begin
        _with_live_app() do app, frame
            Ressac._init_custom_themes!()
            old = Tachikoma.theme()
            try
                Ressac._apply_theme!(:ressac)
                buf = _ui_draw(app, frame)
                @test all(c -> c.style.bg isa Tachikoma.ColorRGB, buf.content)        # plus aucune cellule sans fond
                @test all(c -> c.style.fg isa Tachikoma.ColorRGB ||
                               !haskey(Ressac._RESSAC_REMAP, c.style.fg.code), buf.content)
                @test !any(c -> c.char in ('╭', '╮', '╰', '╯'), buf.content)          # aucun cadre
            finally
                Tachikoma.set_theme!(old)
            end
        end
    end

    @testset "une fenêtre recouvre ce qu'elle couvre et éteint le reste" begin
        _with_live_app() do app, frame
            _set_buffer!(app, "@d1 p\"bd bd bd bd\"\n@d2 p\"hh*8\"")
            _key!(app, 'E')
            ui = Ressac._ui()
            buf = _ui_draw(app, frame)
            (x, y) = _ui_find(buf, "@d1")
            @test _ui_cellat(buf, x, y).style.fg != ui.x
            _exec_ex_command!(app, "mixer")
            buf = _ui_draw(app, frame)
            (x, y) = _ui_find(buf, "PATTERNS")                       # le titre de la pane, sous le voile
            @test _ui_cellat(buf, x, y + 1).style.fg == ui.x
            (mx, my) = _ui_find(buf, "MIXER")
            @test _ui_cellat(buf, mx, my).style.bg == ui.s3          # sa bande de titre
            # Sous la bande, tout le rectangle a le fond de ce qui flotte : rien ne le traverse.
            @test all(dx -> _ui_cellat(buf, mx + dx, my + 1).style.bg == ui.s2, 0:30)
            _key!(app, :escape)
        end
    end

    @testset "la grille du cycle" begin
        ev(start, value) = Ressac.Event(start, start + 1 // 8, value)
        # Des notes écrites en chiffres se lisent en chiffres ; deux chiffres débordent à droite.
        evs = [ev(0 // 1, Dict(:n => 0)), ev(1 // 2, Dict(:n => 12))]
        @test String(Ressac._lane_digits!(Ressac._lane_cells(evs, 0, 8), evs, 0)) == "0   12  "
        # Des hauteurs qui ne sont pas des entiers gardent leurs blocs.
        frac = [ev(0 // 1, Dict(:n => 0.5)), ev(1 // 2, Dict(:n => 7))]
        @test !any(isdigit, Ressac._lane_digits!(Ressac._lane_cells(frac, 0, 8), frac, 0))
        _with_live_app() do app, frame
            _set_buffer!(app, "@d1 p\"bd bd bd bd\"\n@d2 n(\"0 3 7 12\") |> s(\"superpiano\")\n")
            Ressac._patterns_editor(app).cursor_row = 3
            _key!(app, 'E')
            ui = Ressac._ui()
            buf = _ui_draw(app, frame)
            rows = _ui_rows(buf)
            (hx, hy) = _ui_find(buf, "SL ")
            @test occursin(r"SL 1.*2.*3.*4", rows[hy])              # l'en-tête, dans la bande de titre
            (x1, y1) = _ui_find(buf, "d1 █")
            @test count(==('█'), rows[y1]) == 4
            @test occursin(r"d2 0·+3·+7·+12", rows[y1 + 1])
            # Un temps sur deux a un fond, y compris sur une ligne vide.
            x0 = x1 + 3
            w = count(c -> c in ('█', '·'), rows[y1])
            @test _ui_cellat(buf, x0 + 1, y1 + 5).style.bg == ui.s1
            @test _ui_cellat(buf, x0 + w ÷ 4 + 1, y1 + 5).style.bg == ui.bg
            # La ligne du curseur garde son texte : la grille s'efface devant une ligne longue.
            _set_buffer!(app, "@d1 p\"bd\" |> gain(0.5) |> lpf(2000) |> room(0.3) |> pan(0.5) |> hpf(40) |> delay(0.2) |> crush(8) |> speed(1)")
            buf = _ui_draw(app, frame)
            @test occursin("speed(1)", _ui_rows(buf)[_ui_find(buf, "@d1")[2]])
        end
    end
end
