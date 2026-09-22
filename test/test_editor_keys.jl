# Touches de l'éditeur qui attendent un caractère littéral (r, f, t) : rien
# ne doit les intercepter, ni le panic global ni le menu Espace.
using Test
using Ressac
using Tachikoma

if !@isdefined(_EkMock)
    mutable struct _EkMock
        sent::Vector{Vector{UInt8}}
    end
    _EkMock() = _EkMock(Vector{UInt8}[])
    Ressac.send_osc(c::_EkMock, bytes::Vector{UInt8}) = push!(c.sent, bytes)
end

function _ek_app()
    app = Ressac.RessacApp(; scheduler = Ressac.Scheduler(_EkMock(); cps = 0.5))
    tb = Tachikoma.TestBackend(120, 40)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 120, 40),
                            Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    Ressac._PANE_MODE.active = false
    ed = Ressac._active_editor(app)
    ed.mode = :normal
    return app, ed, tb, frame
end
_ekkey(app, c) = Tachikoma.update!(app, Tachikoma.KeyEvent(c))
function _ek_fresh!(app, ed, txt; col = 0)
    Tachikoma.set_text!(ed, txt)
    ed.cursor_row = 1; ed.cursor_col = col; ed.mode = :normal
    ed.pending_key = nothing
    app.pending_leader = false; app.pending_find = nothing
end

@testset "r remplace par n'importe quel caractère, même piégé ailleurs" begin
    app, ed, _, _ = _ek_app()
    for c in ('!', ' ', '%', 'e', ':', '?', ',', 'K')
        _ek_fresh!(app, ed, "abc")
        _ekkey(app, 'r'); _ekkey(app, c)
        @test Tachikoma.text(ed) == string(c) * "bc"
        @test !app.pending_leader            # Espace n'a pas ouvert le menu
        @test ed.mode === :normal
    end
    # `!` seul déclenche toujours le panic, Espace seul ouvre toujours le menu
    _ek_fresh!(app, ed, "abc")
    _ekkey(app, '!')
    @test occursin("PANIC", app.logs[end])
    _ek_fresh!(app, ed, "abc")
    _ekkey(app, ' ')
    @test app.pending_leader
    _ekkey(app, :escape)
end

@testset "f / F / t / T et ; , cherchent un caractère sur la ligne" begin
    app, ed, _, _ = _ek_app()
    _ek_fresh!(app, ed, "a!cd!e")
    _ekkey(app, 'f'); _ekkey(app, '!')
    @test ed.cursor_col == 1
    @test !occursin("PANIC", app.logs[end])          # le panic ne vole pas le `!`
    _ekkey(app, ';'); @test ed.cursor_col == 4       # occurrence suivante
    _ekkey(app, ','); @test ed.cursor_col == 1       # et retour
    _ek_fresh!(app, ed, "abcd"; col = 3)
    _ekkey(app, 'F'); _ekkey(app, 'b'); @test ed.cursor_col == 1
    _ek_fresh!(app, ed, "abcd")
    _ekkey(app, 't'); _ekkey(app, 'd'); @test ed.cursor_col == 2
    _ek_fresh!(app, ed, "abcd"; col = 3)
    _ekkey(app, 'T'); _ekkey(app, 'a'); @test ed.cursor_col == 1
    # caractère absent : le curseur ne bouge pas, rien d'autre ne se déclenche
    _ek_fresh!(app, ed, "abcd")
    n = length(app.logs)
    _ekkey(app, 'f'); _ekkey(app, 'z')
    @test ed.cursor_col == 0 && length(app.logs) == n
    @test app.pending_find === nothing
    # Échap annule l'attente
    _ek_fresh!(app, ed, "abcd")
    _ekkey(app, 'f'); @test app.pending_find == 'f'
    _ekkey(app, :escape)
    @test app.pending_find === nothing && ed.cursor_col == 0
end

@testset "les caractères spéciaux s'écrivent en insertion" begin
    app, ed, _, _ = _ek_app()
    _ek_fresh!(app, ed, "")
    _ekkey(app, 'i')
    for c in "{bd sn}%4 !?"; _ekkey(app, c); end
    @test Tachikoma.text(ed) == "{bd sn}%4 !?"
    @test ed.mode === :insert
    _ekkey(app, :escape)
    # et le polymètre tapé se parse
    @test length(Ressac.parse_minino("{bd sn}%4")(0//1, 1//1)) == 4
end

@testset "pump accepte un symbole comme le reste des combinateurs" begin
    evs = (:pad |> pump(4, 0.7))(0//1, 1//1)
    @test length(evs) == 4
    gains = [ev.value[:gain] for ev in evs]
    @test gains[1] ≈ 0.3 atol = 0.01          # le creux
    @test gains[end] ≈ 1.0 atol = 0.01        # la remontée
    @test issorted(gains)
    @test length((p"bd*4" |> pump(2, 0.5))(0//1, 1//1)) == 4
    # le gain découpe les événements aux intersections (structure des deux
    # côtés) : deux coups sur quatre pas de pompe font quatre fragments
    @test length(("bd sn" |> pump())(0//1, 1//1)) == 4
end

@testset "une suite Julia dans une alternance ou une séquence" begin
    vals(p, a, b) = [ev.value for ev in sort(p(a // 1, b // 1); by = e -> e.start)]
    # seq / _as_pattern : tout dans un cycle, comme [ ]
    @test [ev.value[:n] for ev in sort((:pad |> n(100:300:1000))(0//1, 1//1); by = e -> e.start)] ==
          [100, 400, 700, 1000]
    # slowcat : un par cycle, comme < >
    alt = slowcat(100:300:1000)
    @test vals(alt, 0, 1) == [Symbol("100")]
    @test vals(alt, 1, 2) == [Symbol("400")]
    @test vals(alt, 4, 5) == [Symbol("100")]          # et ça boucle
    @test [ev.value[:cutoff] for ev in (:pad |> lpf(slowcat(200:200:600)))(1//1, 2//1)] == [400]
end

@testset "PgUp / PgDn défilent partout où l'on défile" begin
    for sc in (:wiki, :doc, :log, :modal_text, :modal_help, :modal_browse,
               :modal_patterns, :modal_evolve, :modal_palette, :editor)
        @test Ressac.lookup(sc, "PgDn") !== nothing
        @test Ressac.lookup(sc, "PgUp") !== nothing
    end
    # dans la pane wiki, PgDn fait la même chose que d
    app, ed, _, _ = _ek_app()
    Ressac._open_wiki!(app)
    wp = Ressac._focused_pane_impl(app)
    @test wp isa Ressac.WikiPane
    wp.scroll = 0
    Tachikoma.update!(app, Tachikoma.KeyEvent(:pagedown))
    @test wp.scroll == 10
    Tachikoma.update!(app, Tachikoma.KeyEvent(:pageup))
    @test wp.scroll == 0
    Tachikoma.update!(app, Tachikoma.KeyEvent(:pageup))
    @test wp.scroll == 0                       # borné
end

@testset "disposition de clavier — Maj + touche AZERTY donne le bon caractère" begin
    # Sans le drapeau « touches alternatives », le terminal n'envoie que
    # la touche de base : Tachikoma applique alors une table QWERTY, où
    # ù, é, à n'existent pas. Ressac complète cette table.
    ev(cp) = Tachikoma._kitty_keycode_to_event(cp, true, false, false, Tachikoma.key_press)
    @test ev(Int('ù')).char == '%'
    @test ev(Int('é')).char == '2'
    @test ev(Int('à')).char == '0'
    @test ev(Int('ç')).char == '9'
    @test ev(Int('<')).char == '>'
    @test ev(Int('a')).char == 'A'            # le cas usuel n'est pas touché
    @test ev(Int('5')).char == '%'            # ni la table QWERTY
    @test isdefined(Ressac, :_request_alternate_keys)
end
