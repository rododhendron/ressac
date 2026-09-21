# Ponts son ⟷ patterns : workspaces PLAY / DESIGN / EXPLORE, gs, U,
# :synth <nom> depuis la librairie, :sculpt robuste, export explorer.
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

function _br_app()
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
_bkey(app, c::Char) = Tachikoma.update!(app, Tachikoma.KeyEvent(c))
_bkey(app, s::Symbol) = Tachikoma.update!(app, Tachikoma.KeyEvent(s))
_bex(app, cmd) = (_bkey(app, ':'); foreach(c -> _bkey(app, c), cmd); _bkey(app, :enter))
_bws(app) = Ressac.current_workspace(app.workspaces).name
function _bscreen(app, tb, frame)
    Tachikoma.reset!(tb.buf); Tachikoma.view(app, frame)
    join((Tachikoma.row_text(tb, y) for y in 1:40), "\n")
end
# Sandbox : les ponts écrivent dans plugins/user-synths → on travaille
# dans un répertoire temporaire (pwd() est la racine des chemins).
function _in_sandbox(f)
    dir = mktempdir()
    mkpath(joinpath(dir, "plugins", "user-synths"))
    old = pwd()
    cd(dir)
    try
        f()
    finally
        cd(old)
    end
end

@testset "workspaces — PLAY / DESIGN / EXPLORE au démarrage, remplis à la demande" begin
    app, tb, frame = _br_app()
    names = [w.name for w in app.workspaces.workspaces]
    @test names == ["PLAY", "DESIGN", "EXPLORE"]
    @test _bws(app) == "PLAY"
    @test Ressac._focused_role(app) === :patterns
    scr = _bscreen(app, tb, frame)
    @test occursin("[1 PLAY]", scr) && occursin("2 DESIGN", scr) && occursin("3 EXPLORE", scr)
    _bex(app, "design")
    @test _bws(app) == "DESIGN"
    @test Ressac._focused_role(app) === :synth               # sketch synth pré-rempli
    @test occursin("@synth :sketch", Tachikoma.text(Ressac._active_editor(app)))
    _bex(app, "explore")
    @test _bws(app) == "EXPLORE"
    @test Ressac._focused_pane_impl(app) isa Ressac.SynthExplorerPane
    @test occursin("EXPLORER", _bscreen(app, tb, frame))
    Tachikoma.update!(app, Tachikoma.KeyEvent(:ctrl, '1'))
    @test _bws(app) == "PLAY"
    _bex(app, "play"); @test _bws(app) == "PLAY"
end

@testset ":synth <nom> ouvre la recette de librairie (copie éditable), pas un starter vide" begin
    _in_sandbox() do
        app, tb, frame = _br_app()
        _bex(app, "synth kick")
        @test Ressac._focused_role(app) === :synth
        txt = Tachikoma.text(Ressac._active_editor(app))
        @test occursin("env_perc", txt)                        # la recette, pas sin_osc(:freq) seul
        @test occursin("@synth :kick", txt)
        @test isfile(joinpath(pwd(), "plugins", "user-synths", "kick.jl"))
        # un nom inconnu garde le starter
        _bex(app, "synth zorglub")
        @test occursin("@synth :zorglub", Tachikoma.text(Ressac._active_editor(app)))
        @test !occursin("env_perc", Tachikoma.text(Ressac._active_editor(app)))
    end
end

@testset "gs — ouvre le synth sous le curseur dans DESIGN ; mot inconnu → message" begin
    _in_sandbox() do
        app, tb, frame = _br_app()
        ed = Ressac._active_editor(app)
        Tachikoma.set_text!(ed, "@d1 p\"kick*4\"\n@d2 p\"zorglub\"")
        ed.cursor_row = 1; ed.cursor_col = 8                  # sur « kick »
        _bkey(app, 'g'); _bkey(app, 's')
        @test _bws(app) == "DESIGN"
        @test Ressac._focused_role(app) === :synth
        @test Ressac._current_synth_tab(app).name == "kick"
        @test occursin("env_perc", Tachikoma.text(Ressac._active_editor(app)))
        # retour, mot inconnu
        _bex(app, "play")
        ed = Ressac._active_editor(app)
        ed.cursor_row = 2; ed.cursor_col = 8                  # sur « zorglub »
        n0 = length(app.logs)
        _bkey(app, 'g'); _bkey(app, 's')
        @test _bws(app) == "PLAY"
        @test occursin("pas un synth connu", app.logs[end])
    end
end

@testset "U — depuis une pane synth : sauve, puis @dN p\"nom*4\" dans PLAY" begin
    _in_sandbox() do
        app, tb, frame = _br_app()
        _bex(app, "synth kick")
        @test _bws(app) == "PLAY"                              # :synth ouvre dans le workspace courant
        _bkey(app, 'U')
        @test _bws(app) == "PLAY"
        @test Ressac._focused_role(app) === :patterns
        ed = Ressac._active_editor(app)
        txt = Tachikoma.text(ed)
        @test occursin("@d4 p\"kick*4\"", txt)                # @d1..3 pris par le buffer de démarrage
        @test strip(ed.lines[ed.cursor_row] |> String) == "@d4 p\"kick*4\""
        @test haskey(Ressac._SYNTH_REGISTRY, :kick)             # enregistré → jouable
        @test occursin("ajouté", app.logs[end])
        # depuis DESIGN aussi (sketch)
        _bex(app, "design")
        _bkey(app, 'U')
        @test _bws(app) == "PLAY"
        @test occursin("@d5 p\"sketch*4\"", Tachikoma.text(Ressac._active_editor(app)))
    end
end

@testset ":sculpt — accepte la forme une-ligne ; refuse un synth SC brut avec un message clair" begin
    _in_sandbox() do
        app, tb, frame = _br_app()
        _bex(app, "synth zorglub")                             # starter une-ligne
        _bex(app, "sculpt")
        @test app.modal === :sculpt
        _bkey(app, :escape)
        @test app.modal === :none
        write(joinpath(pwd(), "plugins", "user-synths", "raw.jl"),
              "@synth :raw (freq=220, sustain=0.5) SynthDSL.Sig(\"{ SinOsc.ar(freq) }.value\")\n")
        _bex(app, "sculpt raw")
        @test app.modal === :none
        @test occursin("SC brut", app.logs[end])
        _bex(app, "sculpt nexistepas")
        @test occursin("introuvable", app.logs[end])
        # U depuis le studio sculpt (buffer focalisé = zorglub) : sauve + @dN dans PLAY
        _bex(app, "sculpt")
        @test app.modal === :sculpt
        @test app.sculpt_pane.label == "zorglub"
        _bkey(app, 'U')
        @test app.modal === :none
        @test _bws(app) == "PLAY"
        @test occursin("p\"zorglub*4\"", Tachikoma.text(Ressac._active_editor(app)))
    end
end

@testset "explorer — e (export) ouvre le candidat dans DESIGN" begin
    app, tb, frame = _br_app()
    _bex(app, "explore")
    p = Ressac._focused_pane_impl(app)
    @test p isa Ressac.SynthExplorerPane
    _bkey(app, 'e')                                            # nommage
    foreach(c -> _bkey(app, c), "cand"); _bkey(app, :enter)
    @test _bws(app) == "DESIGN"
    @test Ressac._focused_role(app) === :synth
    @test occursin("@synth", Tachikoma.text(Ressac._active_editor(app)))
    _bex(app, "explore")
    @test Ressac._focused_pane_impl(app) isa Ressac.SynthExplorerPane   # l'explorer est toujours là
end
