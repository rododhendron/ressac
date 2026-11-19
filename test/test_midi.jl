include(joinpath(@__DIR__, "helpers.jl"))
# L'entrée MIDI (roadmap F4) : ce que SuperCollider renvoie par
# /ressac/midi, et où va une note.

@testset "entrée MIDI — la file, puis la note là où elle a un sens" begin
    Ressac._midi_drain!()
    # Le fil d'écoute range ; un message mal formé est ignoré.
    Ressac._handle_midi!(Any["on", 60, 100, 0])
    Ressac._handle_midi!(Any["cc", 7, 64])
    Ressac._handle_midi!(Any["bizarre", 1, 2])
    Ressac._handle_midi!(Any["on"])
    evs = Ressac._midi_drain!()
    @test [(e.kind, e.num, e.val) for e in evs] == [(:on, 60, 100), (:cc, 7, 64)]
    @test isempty(Ressac._midi_drain!())
    # La file est bornée.
    foreach(i -> Ressac._handle_midi!(Any["cc", 1, i % 128, 0]), 1:(Ressac._MIDI_MAX_QUEUE + 50))
    @test length(Ressac._midi_drain!()) == Ressac._MIDI_MAX_QUEUE

    _with_live_app() do app, frame
        mock = app.scheduler.osc
        # Sans rien d'ouvert : un mot dans le journal, une seule fois, rien d'envoyé.
        Ressac._MIDI_HINTED[] = false
        n0 = length(mock.sent)
        Ressac._handle_midi!(Any["on", 60, 100, 0]); Ressac._midi_tick!(app)
        Ressac._handle_midi!(Any["on", 62, 100, 0]); Ressac._midi_tick!(app)
        @test count(l -> occursin("clavier MIDI reçu", l), app.logs) == 1
        @test length(mock.sent) == n0
        # Le piano ouvert : la note le joue à sa vraie hauteur, et s'enregistre.
        _exec_ex_command!(app, "piano-rec superpiano")
        @test app.piano_active
        n0 = length(mock.sent)
        Ressac._handle_midi!(Any["on", 69, 90, 0])            # la 440
        Ressac._handle_midi!(Any["on", 69, 0, 0])             # vélocité 0 = relâchement : ignoré
        Ressac._handle_midi!(Any["off", 69, 0, 0])
        Ressac._midi_tick!(app)
        @test length(mock.sent) == n0 + 1
        msg = Ressac.decode_message(mock.sent[end])
        @test msg.address == "/ressac/play"
        i = findfirst(==("freq"), msg.args)
        @test isapprox(msg.args[i + 1], 440.0; atol = 0.01)
        @test length(app.piano_events) == 1
        @test app.piano_octave * 12 + app.piano_events[1][2] == 69
        _key!(app, :escape)
    end
end

@testset "entrée MIDI — un son ouvert s'entend à la note jouée" begin
    old = pwd(); d = mktempdir(); mkpath(joinpath(d, "plugins", "user-synths")); cd(d)
    try
        (app, _) = _new_app()
        _exec_ex_command!(app, "synth essai")
        Ressac._midi_drain!()
        Ressac._handle_midi!(Any["on", 48, 100, 0])
        Ressac._midi_tick!(app)
        @test app.test_note == 48
    finally
        cd(old)
    end
end
