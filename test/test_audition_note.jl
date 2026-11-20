include(joinpath(@__DIR__, "helpers.jl"))
# Note d'audition (`:note`, T) et affichage de la hauteur dans le titre du texte, quand le curseur est dans un son.
using Test
using Ressac
using Tachikoma

if !@isdefined(_ANMock)
    mutable struct _ANMock
        sent::Vector{Vector{UInt8}}
    end
    _ANMock() = _ANMock(Vector{UInt8}[])
    Ressac.send_osc(c::_ANMock, bytes::Vector{UInt8}) = push!(c.sent, bytes)
end

function _an_app()
    mock = _ANMock()
    sched = Ressac.Scheduler(mock; cps = 0.5)
    app = Ressac.RessacApp(; scheduler = sched)
    tb = Tachikoma.TestBackend(140, 40)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 140, 40),
                            Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    _only_patterns!(app)
    Ressac._PANE_MODE.active = false
    Ressac._active_editor(app).mode = :normal
    return app, tb, frame, mock
end
_ankey(app, c::Char) = Tachikoma.update!(app, Tachikoma.KeyEvent(c))
_ankey(app, s::Symbol) = Tachikoma.update!(app, Tachikoma.KeyEvent(s))
_anex(app, cmd) = (_ankey(app, ':'); foreach(c -> _ankey(app, c), cmd); _ankey(app, :enter))
function _anscreen(app, tb, frame)
    Tachikoma.reset!(tb.buf); Tachikoma.view(app, frame)
    join((Tachikoma.row_text(tb, y) for y in 1:40), "\n")
end
_anlast(mock) = Ressac.decode_message(mock.sent[end])

@testset "note d'audition — :note, T et titre du texte sur un son" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "plugins", "user-synths"))
        cd(dir) do
            app, tb, frame, mock = _an_app()
            old = Ressac._LIVE_SCHEDULER[]
            Ressac._LIVE_SCHEDULER[] = app.scheduler
            try
                # :note hors d'un son : juste un réglage
                @test app.test_note === nothing
                _anex(app, "note c4")
                @test app.test_note == -12
                _anex(app, "note 7")
                @test app.test_note == 7
                _anex(app, "note zz")
                @test app.test_note == 7                              # refusé, inchangé
                @test occursin("[ERROR] :note", app.logs[end])
                _anex(app, "note off")
                @test app.test_note === nothing

                # un son dans le texte, avec freq + sustain ; le curseur est dessus
                Ressac._open_sound!(app, "auditest")
                tab = Ressac._current_sound(app)
                @test tab !== nothing && tab.name == "auditest"
                @test Ressac._sound_write!(tab,
                    "@synth :auditest (freq=220, sustain=0.3, cutoff=800) saw(:freq) |> rlpf(:cutoff, 0.3)")
                info = Ressac._synth_pitch_info(tab)
                @test info.pitch === :freq && info.sustain
                @test Ressac._synth_title_suffix(tab) == "hauteur freq · durée sustain"
                scr = _anscreen(app, tb, frame)
                @test occursin("SON · auditest · hauteur freq · durée sustain", scr)

                # T sans note : evalAndPlay sans paire supplémentaire
                empty!(mock.sent)
                _ankey(app, 'T')
                m0 = _anlast(mock)
                @test m0.address == "/ressac/evalAndPlay" && length(m0.args) == 2
                @test Ressac._AUDITION_ARGS[] == Any[]                 # remis à zéro

                # T avec :note c4 : freq = 130,81 Hz
                _anex(app, "note c4")
                scr = _anscreen(app, tb, frame)
                @test occursin("♪ T=c4", scr)
                # hors du son, le titre redevient celui des patterns et T est celui de vim (T<car>) : rien ne part
                ed = tab.code_editor
                row = ed.cursor_row
                ed.cursor_row = 1
                scr = _anscreen(app, tb, frame)
                @test occursin("PATTERNS", scr) && !occursin("SON · auditest", scr)
                empty!(mock.sent)
                _ankey(app, 'T'); _ankey(app, 'x')
                @test isempty(mock.sent)
                ed.cursor_row = row
                empty!(mock.sent)
                _ankey(app, 'T')
                m1 = _anlast(mock)
                @test m1.address == "/ressac/evalAndPlay" && m1.args[1] == "auditest"
                @test m1.args[3] == "freq" && isapprox(m1.args[4], 130.81; atol = 0.01)
                @test occursin("note c4", app.logs[end])

                # le DSL ajoute toujours freq / sustain : un @synth répond à n
                @test Ressac._sound_write!(tab, "@synth :auditest (amp=0.5) white() |> env_perc(0.01, 0.1)")
                @test Ressac._synth_title_suffix(tab) == "hauteur freq · durée sustain"
                # un texte en SuperCollider ne s'auditionne pas : rien ne part, le journal dit pourquoi
                empty!(mock.sent)
                @test !Ressac._audition_synth_text!(app, tab, "SynthDef(\\auditest, { |out = 0, amp = 0.5| Out.ar(out, WhiteNoise.ar * amp) }).add;")
                @test isempty(mock.sent) && occursin("SuperCollider", app.logs[end])

                # pitch déclaré dans le registre : midinote
                delete!(Ressac._SYNTH_REGISTRY, :auditest)      # T l'a enregistré en user-dsl
                Ressac.register_synth!(Ressac.SynthEntry(:auditest, "user-synths",
                    Dict{String,Any}("pitch" => "midinote")))
                @test Ressac._synth_pitch_info(tab).pitch === :midinote
                empty!(mock.sent)
                _ankey(app, 'T')
                @test _anlast(mock).args[3:4] == ["midinote", 48.0f0]
                delete!(Ressac._SYNTH_REGISTRY, :auditest)
            finally
                Ressac._LIVE_SCHEDULER[] = old
            end
        end
    end
end

@testset "_note_name — convention Tidal (0 = c5)" begin
    @test Ressac._note_name(0) == "c5"
    @test Ressac._note_name(-12) == "c4"
    @test Ressac._note_name(7) == "g5"
    @test Ressac._note_name(-1) == "b4"
    @test Ressac._note_name(13) == "cs6"
end
