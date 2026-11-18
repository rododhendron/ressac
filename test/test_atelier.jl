include(joinpath(@__DIR__, "helpers.jl"))
# Le maillon comme objet texte, et l'atelier — étape E5.

const _AT_SRC = """
@synth :wob (freq=110, sustain=0.5) begin
  saw(:freq)
  |> rlpf(900, 0.3)
  |> tanh_drive(2)
end"""

# Une app avec le son `wob` ouvert, le curseur sur la ligne `row`.
function _at_app(f; row::Int = 3, col::Int = 6, text::AbstractString = _AT_SRC)
    _with_live_app() do app, frame
        Ressac._active_editor(app).mode = :normal
        _exec_ex_command!(app, "synth wob")
        tab = Ressac._current_synth_tab(app)
        ed = tab.code_editor
        Ressac._load_text!(ed, text)
        ed.cursor_row = row; ed.cursor_col = col; ed.mode = :normal
        empty!(app.scheduler.osc.sent)
        f(app, ed, frame)
    end
end
_at_sent(app) = [Ressac.decode_message(b) for b in app.scheduler.osc.sent]
_at_last_sc(app) = (ms = [m for m in _at_sent(app) if m.address == "/ressac/evalAndPlay"]; isempty(ms) ? "" : String(ms[end].args[2]))

@testset "atelier" begin

    @testset "les maillons d'une ligne" begin
        L(s) = Ressac._line_links(collect(s), 1)
        one = L("  |> rlpf(900, 0.3)   # le filtre")
        @test length(one) == 1 && one[1].linewise && one[1].piped && one[1].name == "rlpf"
        @test String(collect("  |> rlpf(900, 0.3)   # le filtre")[one[1].inner]) == "rlpf(900, 0.3)"
        src = L("  saw(:freq)")
        @test length(src) == 1 && src[1].linewise && !src[1].piped && src[1].name == "saw"
        # Plusieurs sur une ligne ; un `|>` dans une parenthèse ou une chaîne n'en est pas un.
        many = L("saw(:freq) |> rlpf(lfo(2) |> range(300, 900), 0.3) |> tanh_drive(2)")
        @test [l.name for l in many] == ["saw", "rlpf", "tanh_drive"] && !any(l -> l.linewise, many)
        s = collect("saw(:freq) |> rlpf(lfo(2) |> range(300, 900), 0.3) |> tanh_drive(2)")
        @test String(s[many[2].around]) == " |> rlpf(lfo(2) |> range(300, 900), 0.3)"
        @test String(s[many[1].around]) == "saw(:freq) |> "                       # le premier prend le pipe qui le suit
        @test isempty(L("   # un commentaire")) && isempty(L(""))
    end

    @testset "dam retire le maillon, yam + p le pose ailleurs, u annule" begin
        _at_app() do app, ed, _
            _type!(app, "dam")
            @test Tachikoma.text(ed) == "@synth :wob (freq=110, sustain=0.5) begin\n  saw(:freq)\n  |> tanh_drive(2)\nend"
            _key!(app, 'u')
            @test Tachikoma.text(ed) == _AT_SRC
            ed.cursor_row = 3
            _type!(app, "yam")
            @test Tachikoma.text(ed) == _AT_SRC && ed.yank_is_linewise
            ed.cursor_row = 4
            _key!(app, 'p')
            @test String(ed.lines[5]) == "  |> rlpf(900, 0.3)"                    # copié sous tanh_drive
            # Le maillon copié vaut dans les autres textes : ici, les patterns.
            @test String(Ressac._patterns_editor(app).yank_buffer[1]) == "  |> rlpf(900, 0.3)"
        end
    end

    @testset "sur une ligne à plusieurs maillons, dam prend le maillon et son pipe" begin
        _at_app(; row = 1, col = 16, text = "saw(:freq) |> rlpf(900, 0.3) |> tanh_drive(2)") do app, ed, _
            _type!(app, "dam")
            @test Tachikoma.text(ed) == "saw(:freq) |> tanh_drive(2)"
        end
    end

    @testset "un opérateur puis a/i et une touche qui n'est pas un objet : rien, et pas d'insertion" begin
        _at_app() do app, ed, _
            _type!(app, "dax")
            @test Tachikoma.text(ed) == _AT_SRC && ed.mode === :normal && app.pending_obj === nothing
        end
    end

    @testset "o propose ce qui peut suivre ; chaque proposition s'entend ; rien n'est écrit avant Entrée" begin
        _at_app() do app, ed, frame
            _key!(app, 'o')
            @test app.modal === :atelier && app.atelier.action === :after
            names = [it.name for it in Ressac._atelier_entries(app)]
            @test "moog_ff" in names && "free_verb" in names && "env_perc" in names && "chorus" in names
            @test !("saw" in names)                                              # une source ne suit pas un maillon
            @test Tachikoma.text(ed) == _AT_SRC
            _type!(app, "free")                                                  # on tape : ça filtre
            @test [it.name for it in Ressac._atelier_entries(app)][1] == "free_verb"
            _key!(app, :down); _key!(app, :up)                                   # on parcourt : ça s'entend
            sc = _at_last_sc(app)
            @test occursin("FreeVerb", sc) && occursin("RLPF", sc) && occursin("tanh", sc)
            # À sa place dans la chaîne : il enveloppe le filtre, et la saturation l'enveloppe.
            @test occursin(r"FreeVerb\.ar\(RLPF\.ar\(", sc) && occursin(r"\)\s*\*\s*2\)\.tanh|\.tanh", sc)
            @test Tachikoma.text(ed) == _AT_SRC                                  # toujours rien d'écrit
            @test (Tachikoma.view(app, frame); true)
            _key!(app, :enter)
            @test app.modal === :none && app.atelier === nothing
            lines = split(Tachikoma.text(ed), '\n')
            @test startswith(lines[4], "  |> free_verb(") && lines[5] == "  |> tanh_drive(2)"
            @test ed.cursor_row == 4 && ed.mode === :normal
            _key!(app, 'u')
            @test Tachikoma.text(ed) == _AT_SRC                                  # un seul u
        end
    end

    @testset "Échap ne change rien, et fait réentendre le son tel qu'il est" begin
        _at_app() do app, ed, _
            _key!(app, 'o'); _type!(app, "moog"); _key!(app, :down)
            @test occursin("MoogFF", _at_last_sc(app))
            _key!(app, :escape)
            @test app.modal === :none && Tachikoma.text(ed) == _AT_SRC
            @test !occursin("MoogFF", _at_last_sc(app))
        end
    end

    @testset "cim remplace : les cousins d'abord, l'original en tête" begin
        _at_app() do app, ed, _
            _type!(app, "cim")
            @test app.modal === :atelier && app.atelier.action === :replace
            items = Ressac._atelier_entries(app)
            @test items[1].name == "rlpf"
            @test all(it -> Ressac._atelier_role(it.name) === :filter, items[2:6])
            _type!(app, "moog_ff"); _key!(app, :enter)
            @test startswith(String(ed.lines[3]), "  |> moog_ff(") && String(ed.lines[4]) == "  |> tanh_drive(2)"
        end
        # Sur la source : ce sont des sources qu'on propose.
        _at_app(; row = 2, col = 3) do app, ed, _
            _type!(app, "cim")
            names = [it.name for it in Ressac._atelier_entries(app)]
            @test "pulse" in names && "sin_osc" in names && !("rlpf" in names)
            _type!(app, "pulse"); _key!(app, :enter)
            @test startswith(String(ed.lines[2]), "  pulse(:freq")
        end
    end

    @testset "O avant un maillon ; rien avant la source ; o hors d'une chaîne reste celui de vim" begin
        _at_app() do app, ed, _
            _key!(app, 'O')
            @test app.modal === :atelier && app.atelier.action === :before
            _type!(app, "high_pass"); _key!(app, :enter)
            @test startswith(String(ed.lines[3]), "  |> high_pass(") && String(ed.lines[4]) == "  |> rlpf(900, 0.3)"
        end
        _at_app(; row = 2) do app, ed, _
            _key!(app, 'O')
            @test app.modal === :none                                            # la source : O est celui de vim
        end
        _at_app(; row = 1) do app, ed, _
            _key!(app, 'o')
            @test app.modal === :none && ed.mode === :insert                     # l'en-tête : une ligne s'ouvre, comme dans vim
        end
    end

    @testset "& m : le nombre bouge, sur une ligne nommée — pas imbriqué" begin
        _at_app(; row = 3, col = 10) do app, ed, _                               # sur 900
            _key!(app, '&')
            @test app.pending_atelier
            _key!(app, 'm')
            lines = split(Tachikoma.text(ed), '\n')
            @test lines[2] == "  mod = lfo(1; low = 630, high = 1170)"
            @test lines[4] == "  |> rlpf(mod, 0.3)"
            @test occursin("RLPF", Core.eval(Ressac.SynthDSL, Ressac.SynthDSL._dsl_parse_all(Tachikoma.text(ed))))
            # Une seconde fois, sur un autre nombre : un autre nom, toujours lisible.
            ed.cursor_row = 4; ed.cursor_col = 17
            _key!(app, '&'); _key!(app, 'm')
            @test occursin("mod2 = lfo(1; low = 0.21, high = 0.39)", Tachikoma.text(ed))
            @test occursin("|> rlpf(mod, mod2)", Tachikoma.text(ed))
        end
    end

    @testset "& k : le nombre devient un argument du son, nommé d'après sa place" begin
        _at_app(; row = 3, col = 16) do app, ed, _                               # sur 0.3 : la résonance de rlpf
            _key!(app, '&'); _key!(app, 'k')
            lines = split(Tachikoma.text(ed), '\n')
            @test lines[1] == "@synth :wob (freq=110, sustain=0.5, rq=0.3) begin"
            @test lines[3] == "  |> rlpf(900, :rq)"
            sc = Core.eval(Ressac.SynthDSL, Ressac.SynthDSL._dsl_parse_all(Tachikoma.text(ed)))
            @test occursin("rq = 0.3", sc)
        end
        @test Ressac._slot_name_at(collect("  |> rlpf(900, 0.3)"), 11) == "freq"
        @test Ressac._slot_name_at(collect("rlpf(saw(220), 900, 0.3)"), 21) == "rq"       # forme directe : le signal d'abord
    end

    @testset "& s : écouter le son jusqu'au maillon du curseur" begin
        _at_app() do app, ed, _
            _key!(app, '&'); _key!(app, 's')
            sc = _at_last_sc(app)
            @test occursin("RLPF", sc) && !occursin("tanh", sc)
            @test Tachikoma.text(ed) == _AT_SRC                                  # le texte n'a pas bougé
        end
    end

    @testset "& b : bifurquer — une copie du son, à part" begin
        _at_app() do app, ed, _
            _key!(app, '&'); _key!(app, 'b')
            tab = Ressac._current_synth_tab(app)
            @test tab.name == "wob2" && occursin("@synth :wob2", Tachikoma.text(tab.code_editor))
            @test Tachikoma.text(ed) == _AT_SRC                                  # l'original est intact
        end
    end

    @testset "& puis une touche inconnue, ou Échap : rien" begin
        _at_app() do app, ed, _
            _key!(app, '&'); _key!(app, :escape)
            @test !app.pending_atelier
            _key!(app, '&'); _key!(app, 'z')
            @test !app.pending_atelier && Tachikoma.text(ed) == _AT_SRC
        end
    end
end

@testset "un nombre est un knob" begin

    @testset "la réglette : le nom de la place, ses bornes, où on en est" begin
        @test Ressac._knob_text("gain", 0.0, 1.5, 0.75) == "gain  0 ━━━━━━●━━━━━ 1.5"
        # Une plage de fréquences se lit en log : 632 Hz est au milieu de 20–20000.
        @test Ressac._knob_position(632.0, 20.0, 20000.0) ≈ 0.5 atol = 0.01
        @test Ressac._knob_position(5.0, 0.0, 1.0) == 1.0                       # hors bornes : en butée
        _at_app(; row = 3, col = 16) do app, ed, frame                        # 0.3 : la résonance de rlpf
            k = Ressac._knob_at(app, ed)
            @test k[1] == "rq" && k[4] == 0.3 && k[2] < k[3]
            Tachikoma.reset!(frame.buffer); Tachikoma.view(app, frame)
            buf = frame.buffer
            rows = [join(buf.content[Tachikoma.buf_index(buf, x, y)].char for x in 1:buf.area.width) for y in 1:buf.area.height]
            row = rows[findfirst(r -> occursin("rlpf(900, 0.3)", r), rows)]
            @test occursin("rq  ", row) && occursin('●', row)
            ed.cursor_col = 2                                                  # plus sur un nombre : plus de réglette
            Tachikoma.reset!(frame.buffer); Tachikoma.view(app, frame)
            rows = [join(buf.content[Tachikoma.buf_index(buf, x, y)].char for x in 1:buf.area.width) for y in 1:buf.area.height]
            @test !occursin('●', rows[findfirst(r -> occursin("rlpf(900, 0.3)", r), rows)])
        end
        # Dans un pattern : le contrôle.
        _with_live_app() do app, _
            _set_buffer!(app, "@d1 p\"hh*8\" |> gain(0.4)", col = 21)
            k = Ressac._knob_at(app, Ressac._patterns_editor(app))
            @test k == ("gain", 0.0, 1.5, 0.4)
        end
    end

    @testset "tirer un nombre d'un slot qui joue le réévalue ; un slot modifié attend son e" begin
        _with_live_app() do app, _
            _set_buffer!(app, "@d1 p\"hh*8\" |> gain(0.4)", col = 21)
            _key!(app, 'E')
            _key!(app, '+')
            @test occursin("gain(1.4)", _buffer_text(app)) || occursin("gain(0.5)", _buffer_text(app))
            ev = first(Ressac.pattern_get(app.scheduler, :d1)(0 // 1, 1 // 1))
            @test ev.value[:gain] != 0.4                                       # ce qu'on entend a suivi
            @test Ressac._slot_line(app, :d1).state === :playing               # et la ligne n'est pas « modifiée »
            # Un slot dont le texte a déjà changé n'est pas évalué par surprise.
            g = ev.value[:gain]
            Ressac._edit_text!(Ressac._patterns_editor(app), replace(_buffer_text(app), "hh*8" => "hh*4"))
            Ressac._patterns_editor(app).cursor_col = 21
            _key!(app, '+')
            @test first(Ressac.pattern_get(app.scheduler, :d1)(0 // 1, 1 // 1)).value[:gain] == g
            @test Ressac._slot_line(app, :d1).state === :modified
        end
    end

    @testset "tirer un nombre d'un son le redéfinit, sans rejouer de note" begin
        _at_app(; row = 3, col = 10) do app, ed, frame                        # 900
            _key!(app, '+'); _key!(app, '+')
            @test occursin("rlpf(902, 0.3)", Tachikoma.text(ed))
            @test app.redefine !== nothing && isempty(_at_sent(app))           # la main bouge encore : rien n'est parti
            app.redefine = (app.redefine[1], time() - 1.0)                     # …elle s'arrête
            Tachikoma.view(app, frame)
            sent = _at_sent(app)
            @test app.redefine === nothing
            @test !isempty(sent) && all(m -> m.address == "/dirt/evalSC", sent)   # défini, pas joué
            @test any(m -> occursin("RLPF.ar(Saw.ar(freq), 902", String(m.args[1])), sent)
            # Un texte en cours de frappe, invalide, ne casse rien.
            Ressac._load_text!(ed, "@synth :wob (freq=110) saw(:freq) |> rlpf(900,")
            @test !Ressac._define_synth_text!(app, Ressac._current_synth_tab(app), Tachikoma.text(ed))
        end
    end
end
