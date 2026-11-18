include(joinpath(@__DIR__, "helpers.jl"))
# Mise en forme d'un son et commentaires — étapes E4.4 et E4.6.

@testset "mise en forme et commentaires" begin

    @testset "format_synth_text : un maillon par ligne, le pipe en tête" begin
        src = """
        # Fast arpeggio voice.
        @synth :arp (freq=220, sustain=0.12) begin
          pulse(:freq, 0.45) |>
          rlpf(:cutoff * 2, 0.3) |>   # le filtre
          env_perc(0.001, :sustain)
        end"""
        out = Ressac.format_synth_text(src)
        @test out == """
        # Fast arpeggio voice.
        @synth :arp (freq=220, sustain=0.12) begin
          pulse(:freq, 0.45)
          |> rlpf(:cutoff * 2, 0.3)  # le filtre
          |> env_perc(0.001, :sustain)
        end"""
        @test Ressac.format_synth_text(out) == out                       # idempotent
        # Le son est le même : le DSL lit les deux formes.
        compile(t) = Core.eval(Ressac.SynthDSL, Ressac.SynthDSL._dsl_parse_all(replace(t, ":cutoff" => "800")))
        @test compile(src) == compile(out)
    end

    @testset "les nombres à queue de décimales sont raccourcis, pas les chaînes ni les commentaires" begin
        src = "n1 = ugen(:AllpassC, 400.0, 5.0350000000000001, 0.00507499999999998)  # 0.123456789 reste\nx = \"3.14159265\""
        out = Ressac.format_synth_text(src)
        @test occursin("ugen(:AllpassC, 400.0, 5.035, 5.075e-3)", out)
        @test occursin("# 0.123456789 reste", out) && occursin("\"3.14159265\"", out)
        @test Ressac.format_synth_text("gain(0.5) |> lpf(1200.25)") == "gain(0.5) |> lpf(1200.25)"   # déjà courts
    end

    @testset "commenter : toutes les lignes, ou décommenter si elles le sont toutes" begin
        lines = ["  saw(:freq)", "  |> rlpf(800, 0.3)", "", "  |> safe()"]
        c = Ressac._toggle_comment_lines(lines, 2, 2)
        @test c == ["  saw(:freq)", "  # |> rlpf(800, 0.3)", "", "  |> safe()"]
        @test Ressac._toggle_comment_lines(c, 2, 2) == lines
        # Un bloc mixte se commente en entier (les vides ne comptent pas) ; puis se décommente d'un geste.
        all_c = Ressac._toggle_comment_lines(c, 1, 4)
        @test all_c == ["  # saw(:freq)", "  # # |> rlpf(800, 0.3)", "", "  # |> safe()"]
        @test Ressac._toggle_comment_lines(all_c, 1, 4) == c
    end

    @testset "gcc court-circuite un maillon ; gcj, gcap ; u annule" begin
        app, _ = _new_app()
        Ressac._active_editor(app).mode = :normal
        _exec_ex_command!(app, "synth gctest")
        ed = Ressac._active_editor(app)
        text = "@synth :gctest (freq=220) begin\n  saw(:freq)\n  |> rlpf(800, 0.3)\n  |> tanh_drive(2)\nend"
        Ressac._edit_text!(ed, text)
        ed.cursor_row = 3
        _type!(app, "gcc")
        @test String(ed.lines[3]) == "  # |> rlpf(800, 0.3)"
        @test ed.mode === :normal && String(ed.lines[4]) == "  |> tanh_drive(2)"   # le second c n'a rien « changé »
        # Le son court-circuité se compile encore.
        sc = Core.eval(Ressac.SynthDSL, Ressac.SynthDSL._dsl_parse_all(Tachikoma.text(ed)))
        @test occursin("tanh", sc) && !occursin("RLPF", sc)
        _type!(app, "gcc")
        @test Tachikoma.text(ed) == text
        _type!(app, "gcj")
        @test String(ed.lines[3]) == "  # |> rlpf(800, 0.3)" && String(ed.lines[4]) == "  # |> tanh_drive(2)"
        _key!(app, 'u')
        @test Tachikoma.text(ed) == text                                  # un geste, un u
        # gc puis une touche qui n'est pas un mouvement : rien, et la touche n'est pas rejouée.
        _type!(app, "gcx")
        @test Tachikoma.text(ed) == text && app.pending_gc === nothing
        # `!` pendant que gc attend n'est pas un PANIC.
        n = length(app.logs)
        _type!(app, "gc!")
        @test !any(l -> occursin("PANIC", l), app.logs[(n + 1):end])
    end

    @testset "gcc sur une ligne @dN : c'est m — commentée et coupée" begin
        _with_live_app() do app, _
            _set_buffer!(app, "@d1 p\"bd\"\n@d2 p\"cp\"")
            _key!(app, 'E')
            _type!(app, "gcc")
            @test startswith(_buffer_text(app), "# @d1")
            @test Ressac.pattern_get(app.scheduler, :d1) === nothing     # le slot est vraiment coupé
            _type!(app, "gcc")
            @test Ressac.pattern_get(app.scheduler, :d1) !== nothing
        end
    end

    @testset ":format met en forme le son ouvert, d'où qu'on soit" begin
        app, _ = _new_app()
        Ressac._active_editor(app).mode = :normal
        _exec_ex_command!(app, "synth fmtest")
        ed = Ressac._active_editor(app)
        Ressac._edit_text!(ed, "@synth :fmtest (freq=220) begin\n  saw(:freq) |>\n  rlpf(800.123456, 0.3)\nend")
        Ressac._focus_patterns!(app)
        _exec_ex_command!(app, "format")                                  # depuis les patterns : le son s'ouvre
        @test app.volet === :son
        @test Tachikoma.text(ed) == "@synth :fmtest (freq=220) begin\n  saw(:freq)\n  |> rlpf(800.123, 0.3)\nend"
        @test any(l -> occursin("rien à changer", l), _cmd_logs(app, "format"))
    end
end

@testset "un commentaire n'avale ni ne coupe une chaîne" begin
    # Dans un son : le commentaire de fin de ligne, et le maillon commenté au milieu.
    pre = Ressac.SynthDSL._dsl_preprocess("saw(:freq)   # la source\n  # |> rlpf(800, 0.3)\n  |> tanh_drive(2)\nx = \"a # b\"")
    @test split(pre, '\n') == ["saw(:freq) |> tanh_drive(2)", "", "", "x = \"a # b\""]      # même nombre de lignes
    # Dans un pattern : idem.
    @test Ressac._join_logical_block(["@d1 p\"bd\"   # le kick", "  # |> lpf(800)", "  |> gain(0.5)"]) ==
          "@d1 p\"bd\" |> gain(0.5)"
    _with_live_app() do app, _
        _set_buffer!(app, "@d1 p\"bd bd\"   # le kick\n  |> lpf(800)\n  |> gain(0.5)")
        _key!(app, 'E')
        ev = first(Ressac.pattern_get(app.scheduler, :d1)(0 // 1, 1 // 1))
        @test ev.value[:gain] == 0.5 && haskey(ev.value, :cutoff)        # le commentaire n'a rien avalé
        # gcc sur le maillon lpf : court-circuité à la prochaine évaluation, le slot joue toujours.
        ed = Ressac._patterns_editor(app); ed.cursor_row = 2
        _type!(app, "gcc")
        @test String(ed.lines[2]) == "  # |> lpf(800)"
        @test Ressac.pattern_get(app.scheduler, :d1) !== nothing          # pas coupé : c'est un maillon, pas le slot
        @test Ressac._slot_line(app, :d1).state === :modified             # ce qu'on lit n'est plus ce qu'on entend
        _key!(app, 'e')
        @test Ressac._slot_line(app, :d1).state === :playing
        # Toucher à un commentaire seul, en revanche, ne « modifie » rien.
        Ressac._edit_text!(ed, replace(Tachikoma.text(ed), "# le kick" => "# la grosse caisse"))
        @test Ressac._slot_line(app, :d1).state === :playing
        ev = first(Ressac.pattern_get(app.scheduler, :d1)(0 // 1, 1 // 1))
        @test ev.value[:gain] == 0.5 && !haskey(ev.value, :cutoff)
    end
end
