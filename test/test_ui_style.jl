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

@testset "un son — texte et DOC côte à côte quand l'écran le permet, la chaîne en tableau" begin
    old = pwd(); d = mktempdir(); mkpath(joinpath(d, "plugins", "user-synths")); cd(d)
    try
        (app, _) = _new_app()
        draw(w) = (tb = Tachikoma.TestBackend(w, 44);
                   f = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, w, 44), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[]);
                   Tachikoma.view(app, f); join((Tachikoma.row_text(tb, y) for y in 1:44), "\n"))
        draw(140)
        _exec_ex_command!(app, "synth essai")
        (ep, sdoc) = Ressac._synth_workspace_parts(app)
        Tachikoma.set_text!(ep.tabs[ep.current_tab].code_editor,
                            "@synth :essai (freq=220, sustain=0.5) saw(:freq) |> rlpf(800, 0.3) |> tanh_drive(2)\n")
        node = app.volets[:son]
        draw(140); draw(140)
        @test node.direction === :v                              # étroit : la DOC sous le texte
        scr = (draw(180); draw(180))
        @test node.direction === :h                              # plus large : côte à côte
        # La DOC s'ouvre sur l'explication, qui commence par la chaîne en tableau.
        @test sdoc.mode === :explain
        @test occursin("CHAÎNE", scr) && occursin("MAILLON", scr) && occursin("RÉGLAGE", scr)
        spans = Ressac.chain_table_spans(sdoc.genome, 60; impacts = Dict(id => 0.5 for id in keys(sdoc.genome.nodes)))
        txt = [join(sp.content for sp in l) for l in spans]
        @test any(l -> occursin("RLPF", l) && occursin("▮▮▮▮▮", l) && occursin("0.5", l), txt)
        # Un maillon qui ne s'entend pas est marqué.
        dead = Ressac.chain_table_spans(sdoc.genome, 60; impacts = Dict(id => 0.001 for id in keys(sdoc.genome.nodes)))
        @test any(l -> occursin("✂", l) && occursin("inaudible", l), [join(sp.content for sp in l) for l in dead])
    finally
        cd(old)
    end
end

@testset "le menu Espace est rangé par intention" begin
    _with_live_app() do app, frame
        _key!(app, ' ')
        buf = _ui_draw(app, frame)
        rows = _ui_rows(buf)
        y = findfirst(r -> occursin("ÉCRIRE", r), rows)
        @test y !== nothing && occursin("TRANSFORMER LA LIGNE", rows[y]) && occursin("OUVRIR", rows[y]) && occursin("FAIRE", rows[y])
        # Toutes les touches du menu sont dans une colonne : rien ne tombe dans « AUTRES ».
        @test !any(r -> occursin("AUTRES", r), rows)
        _key!(app, :escape)
    end
end

@testset "les fenêtres à table : pas de filets, un aperçu sur la grille, la palette par nature" begin
    _with_live_app() do app, frame
        _set_buffer!(app, "@d1 p\"bd bd bd bd\"\n@d2 n(\"0 3 7 12\") |> s(\"superpiano\")\n")
        _key!(app, 'E')
        # Une ligne évaluée « pour voir » rend son pattern sans rien lancer ni rien changer.
        before = length(Ressac.pattern_snapshot(app.scheduler))
        pat = Ressac._pattern_of_line("@d9 n(\"0 12\") |> s(\"superpiano\")")
        @test pat isa Ressac.Pattern
        @test length(Ressac.pattern_snapshot(app.scheduler)) == before
        @test Ressac._ROUTE_CAPTURE[] === nothing
        @test Ressac._pattern_of_line("@d9 pas_une_fonction(") === nothing
        @test String(Ressac._code_lane("@d9 n(\"0 12\") |> s(\"superpiano\")", 24)) == "0           12          "
        # Le mixer : une table sans filets, la ligne choisie sur son fond.
        _exec_ex_command!(app, "mixer")
        buf = _ui_draw(app, frame)
        (mx, my) = _ui_find(buf, "MIXER")
        (sx, sy) = _ui_find(buf, "SLOT")
        @test !any(c -> c in ('│', '─', '┼'), _ui_rows(buf)[sy][sx:min(end, sx + 60)])
        @test _ui_cellat(buf, sx, sy + 2).style.bg == Ressac._ui().s3
        _key!(app, :escape)
        # La palette, sans rien taper : par nature, les commandes avant les fonctions.
        Ressac._open_palette!(app)
        items = Ressac._palette_items(app)
        kinds = [it.kind for it in items]
        @test findfirst(==(:cmd), kinds) < findfirst(==(:func), kinds)
        @test issorted([something(findfirst(==(k), Ressac._PALETTE_ORDER), 99) for k in kinds])
        _key!(app, :escape)
    end
end

@testset "mode visuel — le curseur se voit dans la sélection" begin
    for key in ('v', 'V')
        (app, _) = _new_app()
        tb = Tachikoma.TestBackend(120, 36)
        frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 120, 36), Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
        ed = Ressac._active_editor(app)
        Tachikoma.set_text!(ed, "abcdef xyz\nsecond\n")
        ed.cursor_row = 1; ed.cursor_col = 3
        p = Ressac._ui()
        Tachikoma.update!(app, Tachikoma.KeyEvent(key))
        Tachikoma.update!(app, Tachikoma.KeyEvent('j'))
        @test app.visual_active
        buf = _ui_draw(app, frame)
        (x, y) = _ui_find(buf, "second")
        sel = _ui_cellat(buf, x + 1, y); cur = _ui_cellat(buf, x + 3, y)
        @test sel.style.bg == p.s3                    # la sélection : un fond
        @test cur.char == 'o' && cur.style.bg == p.o  # le curseur : orange, devant
        @test cur.style.bg != sel.style.bg
    end
end
