# Régressions d'entrée et d'analyse remontées en jouant (2026-09-29) :
# surlignage d'un slot commenté, fichier de synth à plusieurs expressions,
# pavé numérique ignoré hors de l'éditeur.
using Test
using Ressac
using Tachikoma

@testset "surlignage rythmique — une ligne commentée n'est plus une cible" begin
    @test match(Ressac._PLAYHEAD_LINE_RX, "# @d1 p\"bd sn\"") === nothing
    @test match(Ressac._PLAYHEAD_LINE_RX, "  # @d1 p\"bd sn\"") === nothing
    mt = match(Ressac._PLAYHEAD_LINE_RX, "  @d2 p\"bd sn\" |> gain(1)")
    @test mt !== nothing && mt.captures[1] == "2" && mt.captures[2] == "bd sn"
    @test Ressac._playhead_parse(collect("# @d1 p\"bd sn\"")) === nothing
    @test Ressac._playhead_parse(collect("@d1 p\"bd sn\"")) !== nothing
end

@testset "fichier de synth à plusieurs expressions — analysé en entier" begin
    src = "# entête\n@synth :t1 (freq=220) begin\n  saw(:freq) |> rlpf(800, 0.3)\nend\n\n# note finale\nx = 1\n"
    @test_throws Base.Meta.ParseError Meta.parse(Ressac.SynthDSL._dsl_preprocess(src))   # l'ancien chemin
    top = Ressac.SynthDSL._dsl_parse_all(src)
    @test top.head === :toplevel
    @test count(a -> !(a isa LineNumberNode), top.args) == 2
    ex = Ressac.SynthDSL._dsl_synth_expr(src)
    @test ex isa Expr && string(ex.args[1]) == "@synth"
    @test Ressac.SynthDSL._dsl_synth_expr("x = 1\ny = 2") === nothing
    @test Ressac.SynthDSL._dsl_synth_expr("@synth :u (") === nothing        # syntaxe cassée : rien, pas d'exception
    g = Ressac.genome_from_dsl(src)
    @test g !== nothing && length(g.nodes) == 2
    @test Ressac.genome_from_dsl("x = 1") === nothing
    @test Ressac.genome_from_dsl("@synth :u (freq=110) sin_osc(:freq)") !== nothing
    # les continuations `|>` en début de ligne survivent au passage
    @test Ressac.genome_from_dsl("@synth :v (freq=110) begin\n  saw(:freq)\n    |> rlpf(500, 0.2)\nend\n# fin\n") !== nothing
end

@testset "pavé numérique — chiffres, point, Entrée, flèches deviennent des touches ordinaires" begin
    n(evt) = Ressac._normalise_event(evt)
    @test n(Tachikoma.KeyEvent(:kp_7)) == Tachikoma.KeyEvent(:char, '7', Tachikoma.key_press)
    @test n(Tachikoma.KeyEvent(:kp_decimal)).char == '.'
    @test n(Tachikoma.KeyEvent(:kp_subtract)).char == '-'
    @test n(Tachikoma.KeyEvent(:kp_equal)).char == '='
    @test n(Tachikoma.KeyEvent(:kp_enter)).key === :enter
    @test n(Tachikoma.KeyEvent(:kp_left)).key === :left
    @test n(Tachikoma.KeyEvent(:kp_pagedown)).key === :pagedown
    @test n(Tachikoma.KeyEvent('a')) == Tachikoma.KeyEvent('a')            # le reste passe tel quel
    @test n(Tachikoma.KeyEvent(:escape)).key === :escape
    # une répétition garde son action
    @test n(Tachikoma.KeyEvent(:kp_3, '\0', Tachikoma.key_repeat)).action === Tachikoma.key_repeat
end

# ── Bout en bout : le pavé numérique dans le studio de sculpture ──────────
# Le bug d'origine : `=` ouvre la saisie, les chiffres du pavé (`:kp_3`…)
# n'y entraient pas parce qu'ils n'étaient traduits qu'après le routage
# vers la pane. Ici on rejoue la scène entière à travers `Tachikoma.update!`.
if !isdefined(Main, :MockOSCClient)
    mutable struct MockOSCClient
        sent::Vector{Vector{UInt8}}
    end
    MockOSCClient() = MockOSCClient(Vector{UInt8}[])
    Ressac.send_osc(c::MockOSCClient, bytes::Vector{UInt8}) = push!(c.sent, bytes)
end

function _ib_app()
    app = Ressac.RessacApp(; scheduler = Ressac.Scheduler(MockOSCClient(); cps = 0.5))
    tb = Tachikoma.TestBackend(120, 40)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 120, 40),
                            Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    Ressac._PANE_MODE.active = false
    Ressac._active_editor(app).mode = :normal
    return app
end
_ib_key(app, k) = Tachikoma.update!(app, Tachikoma.KeyEvent(k))
_ib_ex(app, cmd) = (_ib_key(app, ':'); foreach(c -> _ib_key(app, c), cmd); _ib_key(app, :enter))
function _ib_sandbox(f)
    dir = mktempdir(); mkpath(joinpath(dir, "plugins", "user-synths"))
    old = pwd(); cd(dir)
    try f() finally cd(old) end
end

@testset "sculpt — `=` puis chiffres du pavé puis Entrée du pavé posent la valeur" begin
    _ib_sandbox() do
        app = _ib_app()
        _ib_ex(app, "synth zorglub")
        _ib_ex(app, "sculpt")
        p = Ressac._focused_sculpt_pane(app)
        @test p !== nothing
        p === nothing && return
        @test !isempty(p.knobs)
        _ib_key(app, '=')
        @test p.value_edit
        for k in (:kp_3, :kp_3, :kp_0, :kp_decimal, :kp_5)
            _ib_key(app, k)
        end
        @test p.value_buf == "330.5"
        _ib_key(app, :kp_enter)
        @test !p.value_edit
        kb = p.knobs[clamp(p.focus, 1, length(p.knobs))]
        @test Ressac.knob_value(p.genome, kb) ≈ 330.5
        # Échap du pavé… n'existe pas ; Échap tout court annule sans toucher la valeur
        _ib_key(app, '='); _ib_key(app, :kp_9); _ib_key(app, :escape)
        @test !p.value_edit && Ressac.knob_value(p.genome, kb) ≈ 330.5
    end
end

@testset "coloration — supprimer une ligne re-colore celles qui remontent" begin
    Ressac._install_tk_patches!()
    ed = Tachikoma.CodeEditor(; text = "@d1 p\"bd\"\n# @d2 p\"sn\"\n@d3 p\"hh\"\n# fin\n")
    ed.mode = :normal
    Tachikoma._ensure_tokens!(ed)
    kinds(row) = [t.kind for t in ed.token_cache[row]]
    @test kinds(2) == [Tachikoma.tok_comment]
    # dd sur la ligne commentée : la ligne 3 (`@d3`) devient la ligne 2
    ed.cursor_row = 2
    Tachikoma.handle_key!(ed, Tachikoma.KeyEvent('d')); Tachikoma.handle_key!(ed, Tachikoma.KeyEvent('d'))
    @test String(ed.lines[2]) == "@d3 p\"hh\""
    @test first(kinds(2)) == Tachikoma.tok_macro           # et non plus tok_comment
    @test kinds(3) == [Tachikoma.tok_comment]              # `# fin` a remonté, toujours gris
    # o ouvre une ligne sous le curseur : les lignes du dessous gardent leur couleur
    ed.mode = :normal
    Tachikoma.handle_key!(ed, Tachikoma.KeyEvent('o')); Tachikoma._ensure_tokens!(ed)
    @test length(ed.token_cache) == length(ed.lines) == 5   # texte initial terminé par un saut de ligne
    @test isempty(kinds(3)) && kinds(4) == [Tachikoma.tok_comment]
    # sans passer par les touches : une mutation directe du texte est vue aussi
    ed.lines[1] = collect("# muet"); Tachikoma._ensure_tokens!(ed)
    @test kinds(1) == [Tachikoma.tok_comment]
end

@testset "coloration — V puis c dans Ressac laisse une ligne vide connue du cache" begin
    app = _ib_app()
    ed = Ressac._active_editor(app)
    Tachikoma.set_text!(ed, "@d1 p\"bd\"\n# a\n# b\n@d4 p\"cp\"")
    ed.cursor_row = 2; ed.cursor_col = 0
    _ib_key(app, 'V'); _ib_key(app, 'j'); _ib_key(app, 'c')
    @test ed.mode == :insert
    @test String(ed.lines[2]) == "" && String(ed.lines[3]) == "@d4 p\"cp\""
    Tachikoma._ensure_tokens!(ed)
    @test length(ed.token_cache) == 3
    @test first(ed.token_cache[3]).kind == Tachikoma.tok_macro
end

# ── Une commande ou une touche qui lève ne fait pas tomber l'application ──
@testset "robustesse — :export ouaaha et une action qui lève finissent dans le log" begin
    app = _ib_app()
    n0 = length(app.logs)
    _ib_ex(app, "export ouaaha")
    @test length(app.logs) > n0
    @test occursin("[ERROR] :export attend une durée", app.logs[end]) && occursin(":w ouaaha", app.logs[end])
    # un handler qui lève : attrapé, loggé, la session continue
    Ressac._register_literal!(m -> error("boum"), "boum-test")
    _ib_ex(app, "boum-test")
    @test occursin("[ERROR] :boum-test — boum", app.logs[end])
    delete!(Ressac._LITERAL_DISPATCH, "boum-test")
    # une touche dont l'action lève : pareil
    Ressac.bind!(:global, "Ctrl-y", "test"; action = m -> error("touche cassée"))
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, 'y'))
    @test occursin("[ERROR] touche Ctrl-y", app.logs[end]) && occursin("touche cassée", app.logs[end])
    filter!(b -> !("Ctrl-y" in b.keys), Ressac._KEYMAP[:global])
end
