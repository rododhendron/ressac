# Aide `?` générée depuis le registre — bout en bout via TK.update!.
using Test
using Ressac
import Tachikoma

if !isdefined(Main, :MockOSCClient)
    mutable struct MockOSCClient
        sent::Vector{Vector{UInt8}}
    end
    MockOSCClient() = MockOSCClient(Vector{UInt8}[])
    Ressac.send_osc(c::MockOSCClient, bytes::Vector{UInt8}) = push!(c.sent, bytes)
end

function _help_app()
    sched = Ressac.Scheduler(MockOSCClient(); cps = 0.5)
    app = Ressac.RessacApp(; scheduler = sched)
    tb = Tachikoma.TestBackend(120, 40)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 120, 40),
                            Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    Ressac._PANE_MODE.active = false
    Ressac._active_editor(app).mode = :normal
    return app, tb, frame
end
_hkey(app, c::Char) = Tachikoma.update!(app, Tachikoma.KeyEvent(c))
_hkey(app, s::Symbol) = Tachikoma.update!(app, Tachikoma.KeyEvent(s))
_hex(app, cmd) = (_hkey(app, ':'); foreach(c -> _hkey(app, c), cmd); _hkey(app, :enter))
function _screen(app, tb, frame)
    Tachikoma.reset!(tb.buf); Tachikoma.view(app, frame)
    join((Tachikoma.row_text(tb, y) for y in 1:40), "\n")
end

@testset "help — ? depuis la pane patterns : contexte, toggle, Esc" begin
    app, tb, frame = _help_app()
    _hkey(app, '?')
    @test app.modal === :help
    @test app.help_scopes[1] === :patterns
    @test :leader in app.help_scopes && :global in app.help_scopes
    scr = _screen(app, tb, frame)
    @test occursin("AIDE", scr)
    @test occursin("Pane patterns", scr)
    @test occursin("évaluer la ligne", scr)
    _hkey(app, '?')                                  # toggle
    @test app.modal === :none
    _hkey(app, '?'); _hkey(app, :escape)
    @test app.modal === :none
    _hkey(app, '?'); _hkey(app, 'q')
    @test app.modal === :none
end

@testset "help — :help / :guide / Space ? ouvrent l'aide" begin
    app, tb, frame = _help_app()
    _hex(app, "help");  @test app.modal === :help; _hkey(app, :escape)
    _hex(app, "guide"); @test app.modal === :help; _hkey(app, :escape)
    _hkey(app, ' '); _hkey(app, '?')
    @test app.modal === :help
end

@testset "help — depuis une pane synth, la section synth vient en premier" begin
    app, tb, frame = _help_app()
    _hex(app, "synth kick")
    @test Ressac._focused_role(app) === :synth
    _hkey(app, '?')
    @test app.modal === :help
    @test app.help_scopes[1] === :synth
    @test occursin("tester le synth", _screen(app, tb, frame))
end

@testset "help — depuis une pane non-éditeur (log, explorer) : ? fonctionne" begin
    app, tb, frame = _help_app()
    _hex(app, "vsplit log")
    @test Ressac._focused_role(app) === :other
    _hkey(app, '?')
    @test app.modal === :help
    @test app.help_scopes[1] === :log
    _hkey(app, :escape)
    app2, tb2, frame2 = _help_app()
    _hex(app2, "vsplit explorer")
    _hkey(app2, '?')
    @test app2.modal === :help
    @test app2.help_scopes[1] === :explorer
    scr = _screen(app2, tb2, frame2)
    @test occursin("Explorateur", scr)
    @test occursin("Lecture d'une carte", scr) || app2.modal_scroll == 0   # note de scope présente dans les lignes
    @test any(occursin("Lecture d'une carte", l) for (l, _) in Ressac._help_lines(app2))
end

@testset "help — par-dessus un modal, et retour au modal à la fermeture" begin
    app, tb, frame = _help_app()
    _hex(app, "lib")
    @test app.modal === :synth_library
    _hkey(app, '?')
    @test app.modal === :help
    @test app.help_scopes[1] === :modal_lib
    @test occursin("Librairie de synths", _screen(app, tb, frame))
    _hkey(app, :escape)
    @test app.modal === :synth_library                # restauré
    _hkey(app, :escape)
    @test app.modal === :none
    # browse : ? n'est pas avalé par le filtre texte
    _hex(app, "browse")
    _hkey(app, '?')
    @test app.modal === :help
    @test isempty(app.browser_query)
    _hkey(app, 'q'); @test app.modal === :browse
end

@testset "help — Tab montre toutes les sections, défilement borné" begin
    app, tb, frame = _help_app()
    _hkey(app, '?')
    n_ctx = length(app.help_scopes)
    _hkey(app, :tab)
    @test app.help_expanded
    @test length(app.help_scopes) > n_ctx
    @test :explorer in app.help_scopes && :modal_mixer in app.help_scopes
    last = Ressac._help_last(app)
    _hkey(app, 'G'); @test app.modal_scroll == last
    _hkey(app, 'j'); @test app.modal_scroll == last
    _hkey(app, 'g'); @test app.modal_scroll == 0
    _hkey(app, 'k'); @test app.modal_scroll == 0
    # la référence statique est en queue
    @test any(occursin("MINI-NOTATION", l) for (l, _) in Ressac._help_lines(app))
end

@testset "help — aucun conflit de touches dans le registre" begin
    @test Ressac.keymap_conflicts() == String[]
end
