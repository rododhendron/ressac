include(joinpath(@__DIR__, "helpers.jl"))
# Écrire dans un buffer — roadmap U1 (les accents) et U2 (l'annulation).
#
# Toute édition faite par Ressac passe par `_edit_text!` : elle s'annule
# d'un `u`, et elle compte en caractères comme le curseur.

_ee_app(text; row = 1, col = 0) = (r = _new_app(); _set_buffer!(r[1], text; row, col); r)
_ee_keys!(app, ks::AbstractString) = foreach(c -> _key!(app, c), ks)

@testset "édition — une seule porte d'entrée" begin

    @testset "aucun set_text! direct sur un CodeEditor hors de editor_edit.jl" begin
        src = normpath(joinpath(@__DIR__, "..", "src"))
        offenders = String[]
        for f in readdir(src)
            (endswith(f, ".jl") && f != "editor_edit.jl") || continue
            for (i, line) in enumerate(eachline(joinpath(src, f)))
                occursin("set_text!(", line) || continue
                (occursin("_edit_text!(", line) || occursin("_load_text!(", line)) && continue
                startswith(strip(line), "#") && continue
                # Les saisies de recherche sont des TextInput, pas des CodeEditor.
                occursin(r"set_text!\((m\.browser_search|pk\.input)\b", line) && continue
                push!(offenders, "$f:$i")
            end
        end
        @test offenders == String[]
    end

    @testset "_edit_text! : annulable, défilement gardé, curseur ramené" begin
        ed = Tachikoma.CodeEditor()
        Ressac._load_text!(ed, join(("ligne $i" for i in 1:40), "\n"))
        @test isempty(ed.undo_stack) && (ed.cursor_row, ed.cursor_col) == (1, 0)
        ed.scroll_offset = 12; ed.cursor_row = 20; ed.cursor_col = 3
        Ressac._edit_text!(ed, "court")
        @test Tachikoma.text(ed) == "court" && (ed.cursor_row, ed.cursor_col) == (1, 3) && ed.scroll_offset == 0
        @test length(ed.undo_stack) == 1
        Tachikoma._undo!(ed)
        @test length(ed.lines) == 40
        # Le même texte : rien n'est empilé.
        n = length(ed.undo_stack)
        Ressac._edit_text!(ed, Tachikoma.text(ed); row = 5, col = 2)
        @test length(ed.undo_stack) == n && (ed.cursor_row, ed.cursor_col) == (5, 2)
        # Le défilement tient quand le texte garde sa taille.
        ed.scroll_offset = 12
        Ressac._edit_line!(ed, 20, "changée")
        @test ed.scroll_offset == 12 && String(ed.lines[20]) == "changée"
        @test Ressac._char_col("é abc", 4) == 2 && Ressac._char_span("éé 42", match(r"\d+", "éé 42")) == (3, 5)
        @test Ressac._take_chars("éàü", 2) == "éà" && Ressac._drop_chars("éàü", 2) == "ü" && Ressac._take_chars("é", 9) == "é"
    end

    @testset "U1 — opérateurs vim à droite d'un accent" begin
        for (text, col, keys, want) in (("é abc def", 2, "dw", "é def"),
                                        ("éé abc def", 3, "dw", "éé def"),
                                        ("é abc def", 2, "de", "é  def"),
                                        ("é abc def", 6, "db", "é def"),
                                        ("é abc def", 2, "d\$", "é "),
                                        ("é abc def", 5, "d0", " def"),
                                        ("tempo ×2 après", 9, "dw", "tempo ×2 "),
                                        ("tempo ×2 après fin", 9, "dw", "tempo ×2 fin"))
            app, _ = _ee_app(text; col)
            n = length(app.logs)
            _ee_keys!(app, keys)
            @test _buffer_text(app) == want
            @test !any(l -> occursin("[ERROR]", l), app.logs[(n + 1):end])
        end
        # yw copie les bons caractères ; cw passe en insertion au bon endroit.
        app, _ = _ee_app("é abc def"; col = 2)
        _ee_keys!(app, "yw")
        @test String(Ressac._active_editor(app).yank_buffer[1]) == "abc " && _buffer_text(app) == "é abc def"
        app, _ = _ee_app("é abc def"; col = 2)
        _ee_keys!(app, "cw")
        ed = Ressac._active_editor(app)
        @test _buffer_text(app) == "é  def" && ed.mode === :insert && ed.cursor_col == 2
        _ee_keys!(app, "xyz")
        @test _buffer_text(app) == "é xyz def"
        # c$ jusqu'au bout de la ligne : le curseur se pose après le dernier caractère.
        app, _ = _ee_app("é abc def"; col = 2)
        _ee_keys!(app, "c\$")
        ed = Ressac._active_editor(app)
        @test _buffer_text(app) == "é " && ed.mode === :insert && ed.cursor_col == 2
        # Sur plusieurs lignes.
        # Sur le dernier mot d'une ligne, dw s'arrête à la fin de la ligne
        # (comme vim) : il ne recolle pas la suivante, il ne laisse pas un caractère.
        app, _ = _ee_app("é fin\ndébut ü"; col = 2)
        _ee_keys!(app, "dw")
        @test _buffer_text(app) == "é \ndébut ü"
        app, _ = _ee_app("abc def"; col = 4)
        _ee_keys!(app, "dw")
        @test _buffer_text(app) == "abc "
        app, _ = _ee_app("foo."; col = 0)
        _ee_keys!(app, "dw")
        @test _buffer_text(app) == "."                       # la ponctuation est un autre mot
        # de, ye : `e` après un opérateur est un mouvement, pas « évaluer ».
        app, _ = _ee_app("@d1 \"bd\" fin"; col = 0)
        n = length(app.logs)
        _ee_keys!(app, "de")
        @test _buffer_text(app) == " \"bd\" fin" || _buffer_text(app) == "d1 \"bd\" fin"
        @test !any(l -> occursin("ParseError", l) || occursin("d1 →", l), app.logs[(n + 1):end])
        # Buffer vide : rien ne lève.
        app, _ = _ee_app("")
        _ee_keys!(app, "dw"); _ee_keys!(app, "d\$")
        @test _buffer_text(app) == "" && !any(l -> occursin("[ERROR]", l), app.logs)
    end

    @testset "U1 — sélection visuelle par caractères avec des accents" begin
        app, _ = _ee_app("é abc dèf"; col = 2)
        _ee_keys!(app, "vll")
        _key!(app, 'd')
        @test _buffer_text(app) == "é  dèf"
        app, _ = _ee_app("é abc\ndèf ghi"; col = 2)
        _ee_keys!(app, "vjd")
        @test _buffer_text(app) == "é  ghi"
        app, _ = _ee_app("é abc dèf"; col = 6)
        _ee_keys!(app, "vlly")
        @test String(Ressac._active_editor(app).yank_buffer[1]) == "dèf"
    end

    @testset "U1 — nudge, molette et motif sous le curseur" begin
        # Le nombre est trouvé là où est le curseur, accents à gauche ou non.
        app, _ = _ee_app("# tempo ×2 gain 0.50"; col = 9)
        ed = Ressac._active_editor(app)
        @test Ressac._number_at(ed, 1, 9) == (9, 10, "2")
        @test Ressac._number_at(ed, 1, 8) === nothing            # sur le ×, pas sur le 2
        @test Ressac._has_number_under_cursor(ed)
        Ressac._nudge_number_under_cursor!(app, ed, 1)
        @test _buffer_text(app) == "# tempo ×3 gain 0.50"
        ed.cursor_col = 17
        Ressac._nudge_number_under_cursor!(app, ed, 10)
        @test _buffer_text(app) == "# tempo ×3 gain 0.6"
        @test Ressac._try_nudge_at!(app, ed, 1, 9, -1) && _buffer_text(app) == "# tempo ×2 gain 0.6"
        @test !Ressac._try_nudge_at!(app, ed, 1, 2, 1)
        # La molette sur cette ligne ne lève plus (c'était un StringIndexError qui fermait l'app).
        app, frame = _ee_app("# tempo ×2\n@d1 \"bd*4\""; col = 0)
        Tachikoma.view(app, frame)
        rect = Ressac._focused_editor_rect(app)
        n = length(app.logs)
        for x in rect.x:(rect.x + 16)
            _mouse!(app, x, rect.y + 1, Tachikoma.mouse_scroll_up)
        end
        @test !any(l -> occursin("[ERROR]", l), app.logs[(n + 1):end])
        # Une opération de motif sur une ligne accentuée garde ses guillemets.
        app, _ = _ee_app("mélodie = p\"bd hh sn\""; col = 13)
        info = Ressac._pat_at_cursor(Ressac._active_editor(app))
        @test info !== nothing && info.body == "bd hh sn" && info.body_start_col == 12
        Ressac._pat_replace_body!(app, Ressac._active_editor(app), info, "bd ~ hh ~ sn ~")
        @test _buffer_text(app) == "mélodie = p\"bd ~ hh ~ sn ~\""
    end

    @testset "U2 — chaque édition de Ressac s'annule d'un u, une à la fois" begin
        app, _ = _ee_app("one two three")
        _ee_keys!(app, "x")
        @test _buffer_text(app) == "ne two three"
        _ee_keys!(app, "dw")
        @test _buffer_text(app) == "two three"
        _key!(app, 'u')
        @test _buffer_text(app) == "ne two three"            # seulement le dw
        _key!(app, 'u')
        @test _buffer_text(app) == "one two three"
        # Nudge, raccourci de pattern, mute, opération visuelle : un u chacun.
        for (text, col, act!, changed) in (
                ("@d1 \"bd*4\" |> gain(0.8)", 19, a -> Ressac._nudge_number_under_cursor!(a, Ressac._active_editor(a), 10), "0.9"),
                ("@d1 \"bd*4\"", 0, a -> _exec_ex_command!(a, "sg0.5"), "gain(0.5)"),
                ("@d1 \"bd*4\"", 0, a -> _key!(a, 'm'), "# @d1"),
                ("a\nb\nc", 0, a -> _ee_keys!(a, "Vjd"), "c"))
            app, _ = _ee_app(text; col)
            act!(app)
            @test occursin(changed, _buffer_text(app)) && _buffer_text(app) != text
            _key!(app, 'u')
            @test _buffer_text(app) == text
        end
        # Sur un buffer tout juste chargé, un snippet s'annule aussi.
        app, _ = _new_app()
        ed = Ressac._active_editor(app)
        Ressac._load_text!(ed, "@d1 \"bd\""); ed.mode = :normal
        _exec_ex_command!(app, "sg0.5")
        @test _buffer_text(app) == "@d1 \"bd\" |> gain(0.5)"
        _key!(app, 'u')
        @test _buffer_text(app) == "@d1 \"bd\""
    end

    @testset "U5 — en visuel, m et e portent sur toute la sélection" begin
        text = "@d1 \"bd*4\"\n@d2 \"hh*8\"\n    |> gain(0.5)\n@d3 \"cp\"\n@d4 \"oh\""
        app, _ = _ee_app(text)
        Ressac._LIVE_SCHEDULER[] = app.scheduler
        try
            # V j j j : les lignes 1 à 4, soit d1, d2 (deux lignes) et d3.
            _ee_keys!(app, "Vjjj")
            _key!(app, 'e')
            @test sort(Ressac.pattern_keys(app.scheduler)) == [:d1, :d2, :d3]
            @test !app.visual_active
            _ee_keys!(app, "ggVjjj")
            _key!(app, 'm')
            @test _buffer_text(app) == "# @d1 \"bd*4\"\n# @d2 \"hh*8\"\n#     |> gain(0.5)\n# @d3 \"cp\"\n@d4 \"oh\""
            @test isempty(Ressac.pattern_keys(app.scheduler))
            _key!(app, 'u')                                      # un seul u pour tout le groupe
            @test _buffer_text(app) == text
            # Tous déjà muets : m les remet tous.
            _ee_keys!(app, "ggVjjj"); _key!(app, 'm')
            _ee_keys!(app, "ggVjjj"); _key!(app, 'm')
            @test _buffer_text(app) == text
            # Une partie muette : m coupe ceux qui jouent encore, sans rallumer les autres.
            _set_buffer!(app, "# @d1 \"bd\"\n@d2 \"hh\"")
            _ee_keys!(app, "Vj"); _key!(app, 'm')
            @test _buffer_text(app) == "# @d1 \"bd\"\n# @d2 \"hh\""
            # Sans slot dans la sélection : un message, rien ne change.
            _set_buffer!(app, "x = 1\ny = 2")
            _ee_keys!(app, "Vj"); _key!(app, 'm')
            @test _buffer_text(app) == "x = 1\ny = 2" && any(l -> occursin("aucun slot @dN dans la sélection", l), app.logs)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "U9 — sélection et trous de snippet appartiennent à leur buffer" begin
        # Un snippet à trous, puis la ligne disparaît : Tab ne lève pas, l'état tombe.
        app, frame = _ee_app("@d1 \"bd\"\n")
        ed = Ressac._active_editor(app)
        ed.cursor_row = 2
        Ressac._expand_snippet!(app, ed, "|> gain(\$1) |> pan(\$2)")
        @test app.placeholder_active && app.transient_ed === ed
        _ee_keys!(app, "dd")
        n = length(app.logs)
        _key!(app, :tab); _key!(app, :tab)
        @test !app.placeholder_active
        @test !any(l -> occursin("[ERROR]", l), app.logs[(n + 1):end])
        # Une sélection visuelle ne survit pas à un changement de pane.
        app, frame = _ee_app("a\nb\nc")
        _ee_keys!(app, "Vj")
        @test app.visual_active
        Ressac.cmd_split!(app.workspaces, "editor", Dict{String,Any}())
        Tachikoma.view(app, frame)
        @test !app.visual_active                                # un autre texte a le focus
        # …ni à un changement de workspace, pour les trous.
        app, frame = _ee_app("@d1 \"bd\"")
        Ressac._expand_snippet!(app, Ressac._active_editor(app), " |> gain(\$1)")
        @test app.placeholder_active
        Ressac._switch_workspace_named!(app, "EXPLORE")
        Tachikoma.view(app, frame)
        @test !app.placeholder_active
    end

end
