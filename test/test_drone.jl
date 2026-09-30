# Drones : variante à porte du DSL, registre + OSC, D / T dans l'éditeur,
# pane MODULATION (clavier, saisie, molette), hush / panic / fermeture.
using Test
using Ressac
using Tachikoma

if !@isdefined(_DRMock)
    mutable struct _DRMock
        sent::Vector{Vector{UInt8}}
    end
    _DRMock() = _DRMock(Vector{UInt8}[])
    Ressac.send_osc(c::_DRMock, bytes::Vector{UInt8}) = push!(c.sent, bytes)
end

function _dr_app()
    mock = _DRMock()
    sched = Ressac.Scheduler(mock; cps = 0.5)
    app = Ressac.RessacApp(; scheduler = sched)
    tb = Tachikoma.TestBackend(140, 40)
    frame = Tachikoma.Frame(tb.buf, Tachikoma.Rect(1, 1, 140, 40),
                            Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    ws = Ressac.current_workspace(app.workspaces)
    for leaf in Ressac._all_leaves(ws.tree)
        if any(t -> t isa Ressac.EditorPane, leaf.tabs)
            ws.tree = leaf; ws.focused_pane = leaf.id; break
        end
    end
    Ressac._PANE_MODE.active = false
    Ressac._active_editor(app).mode = :normal
    return app, tb, frame, mock
end
_drkey(app, c::Char) = Tachikoma.update!(app, Tachikoma.KeyEvent(c))
_drkey(app, s::Symbol) = Tachikoma.update!(app, Tachikoma.KeyEvent(s))
function _drscreen(app, tb, frame)
    Tachikoma.reset!(tb.buf); Tachikoma.view(app, frame)
    join((Tachikoma.row_text(tb, y) for y in 1:40), "\n")
end
_drmsgs(mock) = [Ressac.decode_message(b) for b in mock.sent]
_drlast(mock, addr) = (ms = filter(m -> m.address == addr, _drmsgs(mock)); isempty(ms) ? nothing : ms[end])
_drpairs(m, from) = Dict(Symbol(m.args[i]) => m.args[i + 1] for i in from:2:length(m.args) - 1)
# Focalise la (première) pane synth — `_find_pane(EditorPane)` rendrait PATTERNS.
function _dr_focus_synth!(app)
    syn = Ressac._all_synth_buffers(app)
    isempty(syn) && return
    Ressac.current_workspace(app.workspaces).focused_pane = syn[1][1].id
    Ressac._active_editor(app).mode = :normal
end

const _DR_SRC = "@synth :dronetest (freq=220, cutoff=800, sustain=0.5) saw(:freq) |> rlpf(:cutoff, 0.3)"

@testset "drone — variante à porte du DSL" begin
    sig = Ressac.SynthDSL.saw(:freq) |> s -> Ressac.SynthDSL.rlpf(s, :cutoff, 0.3)
    src = Ressac.SynthDSL.build_drone_synth(:zz, sig; params = (freq = 110, cutoff = 800))
    @test occursin("SynthDef(\\zz_drone", src)
    @test occursin("EnvGen.kr(Env.asr(0.01, 1, release), gate, doneAction: 2)", src)
    @test occursin("gate = 1", src) && occursin("release = 0.1", src)
    @test !occursin("Env.linen", src)
    # une enveloppe écrite à la main ne libère plus le nœud : la porte s'en charge
    sig2 = Ressac.SynthDSL.env_perc(sig, 0.01, 0.3)
    src2 = Ressac.SynthDSL.build_drone_synth(:zz, sig2; params = (freq = 110,))
    @test count("doneAction: 2", src2) == 1 && occursin("doneAction: 0", src2)
    # un release déclaré par le synth est gardé tel quel
    src3 = Ressac.SynthDSL.build_drone_synth(:zz, sig; params = (freq = 110, release = 2.0))
    @test occursin("release = 2.0", src3) && count("release = ", src3) == 1
    @test Ressac.SynthDSL.drone_def_name(:acid) === :acid_drone

    names, defs = Ressac.drone_params((freq = 220, sustain = 0.5, gain = 0.5, cutoff = 800, gate = 1))
    @test names == [:freq, :sustain, :gain, :cutoff, :release]
    @test defs[:release] == 0.1 && defs[:cutoff] == 800.0
    names2, _ = Ressac.drone_params((freq = 220, release = 1.5))
    @test names2 == [:freq, :release]

    # pas de modulation : log pour les fréquences, linéaire sinon
    @test Ressac.drone_step(440.0, 220.0, 24) ≈ 880.0
    @test Ressac.drone_step(440.0, 220.0, -24) ≈ 220.0
    @test Ressac.drone_step(0.5, 0.5, 1) ≈ 0.5 + 1 / 24
    @test Ressac.drone_step(0.0, 0.0, -1) ≈ -1 / 24
end

@testset "drone — registre et messages OSC" begin
    mock = _DRMock()
    sched = Ressac.Scheduler(mock; cps = 0.5)
    old = Ressac._LIVE_SCHEDULER[]
    Ressac._LIVE_SCHEDULER[] = sched
    empty!(Ressac._DRONES)
    try
        names = [:freq, :release]; defs = Dict(:freq => 220.0, :release => 0.1)
        d = Ressac.drone_start!(:zz, :zz, :zz_drone, "SynthDef(\\zz_drone…", names, defs)
        m = _drlast(mock, "/ressac/drone/start")
        @test m.args[1:3] == ["zz", "zz_drone", "SynthDef(\\zz_drone…"]
        @test _drpairs(m, 4) == Dict(:freq => 220.0f0, :release => 0.1f0)
        @test Ressac.drone_running(:zz) && Ressac.drone_get(:zz) === d

        Ressac.drone_set!(d, :freq, 330)
        m = _drlast(mock, "/ressac/drone/set")
        @test m.args == Any["zz", "zz_drone", "freq", 330.0f0]
        @test d.values[:freq] == 330.0

        # redémarrage sous le même id : les valeurs passées sont gardées, le registre n'a qu'une entrée
        d2 = Ressac.drone_start!(:zz, :zz, :zz_drone, "", names, defs; values = d.values)
        @test length(Ressac.drone_list()) == 1 && d2.values[:freq] == 330.0
        m = _drlast(mock, "/ressac/drone/start")
        @test m.args[3] == "" && _drpairs(m, 4)[:freq] == 330.0f0

        @test Ressac.drone_stop!(:zz)
        @test _drlast(mock, "/ressac/drone/stop").args == Any["zz"]
        @test !Ressac.drone_running(:zz) && !Ressac.drone_stop!(:zz)

        Ressac.drone_start!(:a, :a, :a_drone, "", names, defs)
        Ressac.drone_start!(:b, :b, :b_drone, "", names, defs)
        @test Ressac.drone_stop_all!() == 2
        @test _drlast(mock, "/ressac/drone/stop").args == Any["*"]
        @test isempty(Ressac.drone_list()) && Ressac.drone_stop_all!() == 0
    finally
        Ressac._LIVE_SCHEDULER[] = old
        empty!(Ressac._DRONES)
    end
end

@testset "drone — l'installation d'un synth pose aussi son jumeau à porte" begin
    mock = _DRMock()
    sched = Ressac.Scheduler(mock; cps = 0.5)
    old = Ressac._LIVE_SCHEDULER[]
    Ressac._LIVE_SCHEDULER[] = sched
    Ressac._INSTALLING_SYNTH[] = true
    try
        Ressac.SynthDSL.play_synth(:twin, Ressac.SynthDSL.saw(:freq); params = (freq = 110,))
        ms = filter(m -> m.address == "/dirt/evalSC", _drmsgs(mock))
        @test length(ms) == 2
        @test occursin("SynthDef(\\twin,", ms[1].args[1])
        @test occursin("SynthDef(\\twin_drone,", ms[2].args[1]) && occursin("Env.asr", ms[2].args[1])
    finally
        Ressac._INSTALLING_SYNTH[] = false
        Ressac._LIVE_SCHEDULER[] = old
        delete!(Ressac._SYNTH_REGISTRY, :twin)
    end
end

@testset "drone — D / T dans l'éditeur, pane MODULATION" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "plugins", "user-synths"))
        cd(dir) do
            app, tb, frame, mock = _dr_app()
            old = Ressac._LIVE_SCHEDULER[]
            Ressac._LIVE_SCHEDULER[] = app.scheduler
            empty!(Ressac._DRONES)
            try
                Ressac._open_synth_tab!(app, "dronetest")
                tab = Ressac._current_synth_tab(app)
                Tachikoma.set_text!(tab.code_editor, _DR_SRC)
                tab.code_editor.mode = :normal

                # D : rien n'est joué en one-shot, le drone démarre avec les défauts
                empty!(mock.sent)
                _drkey(app, 'D')
                @test _drlast(mock, "/ressac/evalAndPlay") === nothing
                m = _drlast(mock, "/ressac/drone/start")
                @test m !== nothing && m.args[1] == "dronetest" && m.args[2] == "dronetest_drone"
                @test occursin("SynthDef(\\dronetest_drone", m.args[3])
                kv = _drpairs(m, 4)
                @test kv[:freq] == 220.0f0 && kv[:cutoff] == 800.0f0 && kv[:release] == 0.1f0
                d = Ressac.drone_get(:dronetest)
                @test d !== nothing && d.origin === :editor && d.names == [:freq, :sustain, :gain, :cutoff, :release]
                @test occursin("drone dronetest ▶", app.logs[end])

                # la pane MODULATION est ouverte, le focus est resté sur l'éditeur
                p = Ressac._find_pane(app, Ressac.DronePane)
                @test p isa Ressac.DronePane
                @test Ressac._focused_role(app) === :synth
                scr = _drscreen(app, tb, frame)
                @test occursin("MODULATION · dronetest ▶ dron", scr)
                @test occursin(r"▸ freq\s+220\s+─+●─+", scr)
                @test occursin(r"cutoff\s+800", scr)

                # T réévalue le drone (nouveau start, pas d'evalAndPlay), sans rafale
                empty!(mock.sent)
                _drkey(app, 'T')
                @test _drlast(mock, "/ressac/evalAndPlay") === nothing
                @test _drlast(mock, "/ressac/drone/start") !== nothing
                @test occursin("réévalué", app.logs[end])
                Ressac._fire_t_with_accel!(app; held = true)
                @test count(m -> m.address == "/ressac/drone/start", _drmsgs(mock)) == 1
                d = Ressac.drone_get(:dronetest)      # nouveau nœud, nouvel objet

                # dans la pane : j → cutoff… (freq, sustain, gain, cutoff), l module en log
                Ressac._focus_pane!(app, p)
                _drkey(app, 'j'); _drkey(app, 'j'); _drkey(app, 'j')
                @test p.focus == 4
                empty!(mock.sent)
                _drkey(app, 'l')
                m = _drlast(mock, "/ressac/drone/set")
                @test m.args[1:3] == Any["dronetest", "dronetest_drone", "cutoff"]
                @test isapprox(m.args[4], 800 * 2^(1 / 24); rtol = 1e-5)
                @test isapprox(d.values[:cutoff], 800 * 2^(1 / 24); rtol = 1e-5)
                _drkey(app, 'L')
                @test isapprox(d.values[:cutoff], 800 * 2^(7 / 24); rtol = 1e-5)
                scr = _drscreen(app, tb, frame)
                @test occursin(r"▸ cutoff\s+979\.", scr)

                # = 1200 ⏎ pose la valeur ; 0 revient au défaut
                _drkey(app, '='); foreach(c -> _drkey(app, c), "1200"); 
                scr = _drscreen(app, tb, frame)
                @test occursin(r"▸ cutoff\s+= 1200▏", scr)
                _drkey(app, :enter)
                @test d.values[:cutoff] == 1200.0
                @test _drlast(mock, "/ressac/drone/set").args[4] == 1200.0f0
                _drkey(app, '0')
                @test d.values[:cutoff] == 800.0

                # k remonte, h en linéaire sur gain
                _drkey(app, 'k')
                @test p.focus == 3
                _drkey(app, 'h')
                @test isapprox(d.values[:gain], 0.5 - 1 / 24)

                # T depuis la pane synth garde les réglages
                _dr_focus_synth!(app)
                _drkey(app, 'T')
                d = Ressac.drone_get(:dronetest)
                @test isapprox(d.values[:gain], 0.5 - 1 / 24)
                @test _drpairs(_drlast(mock, "/ressac/drone/start"), 4)[:gain] ≈ Float32(0.5 - 1 / 24)

                # D relâche
                empty!(mock.sent)
                _drkey(app, 'D')
                @test _drlast(mock, "/ressac/drone/stop").args == Any["dronetest"]
                @test !Ressac.drone_running(:dronetest)
                @test occursin("relâché", app.logs[end])
                scr = _drscreen(app, tb, frame)
                @test occursin("(aucun drone)", scr)

                # une erreur de DSL ne lance rien
                Tachikoma.set_text!(tab.code_editor, "@synth :dronetest (freq=220) saw(:freq) |> rlpf(")
                empty!(mock.sent)
                _drkey(app, 'D')
                @test _drlast(mock, "/ressac/drone/start") === nothing
                @test occursin("[ERROR]", app.logs[end])
                @test Ressac._DRONE_CAPTURE[] === nothing

                # x dans la pane relâche, X relâche tout ; hush et panic aussi
                Tachikoma.set_text!(tab.code_editor, _DR_SRC)
                _drkey(app, 'D')
                @test Ressac.drone_running(:dronetest)
                Ressac._focus_pane!(app, p)
                _drkey(app, 'x')
                @test !Ressac.drone_running(:dronetest)
                _dr_focus_synth!(app)
                _drkey(app, 'D')
                _drkey(app, ',')
                @test isempty(Ressac.drone_list()) && occursin("1 drone(s) relâché(s)", app.logs[end])
                _drkey(app, 'D')
                _drkey(app, '!')
                @test isempty(Ressac.drone_list())

                # fermer la pane synth relâche son drone
                _drkey(app, 'D')
                @test Ressac.drone_running(:dronetest)
                Ressac._close_active_synth_tab!(app)
                @test !Ressac.drone_running(:dronetest)
                @test _drlast(mock, "/ressac/drone/stop").args == Any["dronetest"]
            finally
                Ressac._LIVE_SCHEDULER[] = old
                empty!(Ressac._DRONES)
            end
        end
    end
end

@testset "drone — souris dans la pane MODULATION" begin
    app, tb, frame, mock = _dr_app()
    old = Ressac._LIVE_SCHEDULER[]
    Ressac._LIVE_SCHEDULER[] = app.scheduler
    empty!(Ressac._DRONES)
    try
        names = [:freq, :cutoff, :release]
        defs = Dict(:freq => 220.0, :cutoff => 800.0, :release => 0.1)
        d = Ressac.drone_start!(:mouse, :mouse, :mouse_drone, "", names, defs)
        p = Ressac._place_pane!(app, :drone, Dict{String,Any}())
        @test p isa Ressac.DronePane
        _drscreen(app, tb, frame)
        @test length(p.rows) == 3
        (y2, x2, _) = p.rows[2]
        Tachikoma.update!(app, Tachikoma.MouseEvent(x2 + 3, y2, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
        @test p.focus == 2
        Tachikoma.update!(app, Tachikoma.MouseEvent(x2 + 3, y2, Tachikoma.mouse_scroll_up, Tachikoma.mouse_press, false, false, false))
        @test isapprox(d.values[:cutoff], 800 * 2^(1 / 24); rtol = 1e-5)
        (y1, x1, _) = p.rows[1]
        Tachikoma.update!(app, Tachikoma.MouseEvent(x1 + 3, y1, Tachikoma.mouse_scroll_down, Tachikoma.mouse_press, false, false, false))
        @test p.focus == 1 && isapprox(d.values[:freq], 220 * 2^(-1 / 24); rtol = 1e-5)
        # deux drones : Tab passe de l'un à l'autre
        Ressac.drone_start!(:second, :second, :second_drone, "", names, defs)
        Ressac._focus_pane!(app, p)
        _drkey(app, :tab)
        @test p.current == 2
        scr = _drscreen(app, tb, frame)
        @test occursin("MODULATION · second ▶ second  (2/2 ⇥)", scr)
    finally
        Ressac._LIVE_SCHEDULER[] = old
        empty!(Ressac._DRONES)
    end
end

@testset "drone — côté PLAY : drone() sur un slot" begin
    mock = _DRMock()
    sched = Ressac.Scheduler(mock; cps = 0.5)
    old = Ressac._LIVE_SCHEDULER[]
    Ressac._LIVE_SCHEDULER[] = sched
    empty!(Ressac._DRONES)
    Ressac.register_synth!(Ressac.SynthEntry(:playdrone, "user-dsl",
        Dict{String,Any}("params" => Dict{String,Any}("freq" => 220, "cutoff" => 800, "sustain" => 0.5, "gain" => 0.5))))
    try
        pat = :playdrone |> Ressac.drone() |> Ressac.set(:cutoff, "<400 800>") |> Ressac.set(:freq, 110)
        evs = pat(0 // 1, 2 // 1)
        @test length(evs) == 2
        m = Ressac.event_to_osc(evs[1]; cps = 0.5)
        @test m.address == "/ressac/drone/set"
        @test m.args[1] == "" && m.args[2] == "playdrone_drone"
        kv = _drpairs(m, 3)
        @test kv[:cutoff] == 400.0f0 && kv[:freq] == 110.0f0
        @test !haskey(kv, :drone) && !haskey(kv, :sustain)     # le nœud tient tout seul
        # le slot est posé à l'envoi, et le registre suit
        Ressac._inject_orbit!(m, :d1)
        @test m.args[1] == "d1"
        Ressac._drone_mirror!(:d1, m)
        d = Ressac.drone_get(:d1)
        @test d !== nothing && d.origin === :slot && d.synth === :playdrone && d.def === :playdrone_drone
        @test d.values[:cutoff] == 400.0 && d.values[:freq] == 110.0 && d.values[:gain] == 0.5
        @test d.defaults[:cutoff] == 800.0 && :release in d.names
        @test d.names[1:2] == [:cutoff, :freq]                    # ce que le pattern pilote d'abord
        m2 = Ressac._inject_orbit!(Ressac.event_to_osc(evs[2]; cps = 0.5), :d1)
        Ressac._drone_mirror!(:d1, m2)
        @test Ressac.drone_get(:d1).values[:cutoff] == 800.0
        @test length(Ressac.drone_list()) == 1

        # la pane module aussi un drone de slot
        Ressac.drone_set!(d, :cutoff, 1000)
        @test _drlast(mock, "/ressac/drone/set").args == Any["d1", "playdrone_drone", "cutoff", 1000.0f0]

        # changer le pattern du slot relâche le nœud ; vider aussi ; hush aussi
        Ressac.set_pattern!(sched, :d1, pat)
        @test !Ressac.drone_running(:d1)
        @test _drlast(mock, "/ressac/drone/stop").args == Any["d1"]
        Ressac._drone_mirror!(:d2, Ressac._inject_orbit!(Ressac.event_to_osc(evs[1]; cps = 0.5), :d2))
        Ressac.unset_pattern!(sched, :d2)
        @test !Ressac.drone_running(:d2)
        Ressac._drone_mirror!(:d3, Ressac._inject_orbit!(Ressac.event_to_osc(evs[1]; cps = 0.5), :d3))
        # un drone d'éditeur n'est pas touché par le hush du scheduler
        Ressac.drone_start!(:ed, :ed, :ed_drone, "", [:freq], Dict(:freq => 220.0))
        Ressac.hush!(sched)
        @test !Ressac.drone_running(:d3) && Ressac.drone_running(:ed)
        Ressac.drone_stop_all!()

        # drone(0) : le slot joue ses notes
        pat0 = :playdrone |> Ressac.drone(0)
        m0 = Ressac.event_to_osc(pat0(0 // 1, 1 // 1)[1]; cps = 0.5)
        @test m0.address == "/ressac/play" && !("drone" in m0.args)

        # un sample ignore drone()
        ms = Ressac.event_to_osc((:bd |> Ressac.drone())(0 // 1, 1 // 1)[1]; cps = 0.5)
        @test ms.address == "/dirt/play"
    finally
        Ressac._LIVE_SCHEDULER[] = old
        empty!(Ressac._DRONES)
        delete!(Ressac._SYNTH_REGISTRY, :playdrone)
    end
end

@testset "drone — le scheduler qui tire un slot en drone remplit le registre" begin
    mock = _DRMock()
    sched = Ressac.Scheduler(mock; cps = 1.0, lookahead = 0.05)
    sched.t_start = 0.0
    empty!(Ressac._DRONES)
    Ressac.register_synth!(Ressac.SynthEntry(:tickdrone, "user-dsl",
        Dict{String,Any}("params" => Dict{String,Any}("freq" => 220, "cutoff" => 800))))
    try
        Ressac.set_pattern!(sched, :d4, :tickdrone |> Ressac.drone() |> Ressac.set(:cutoff, 500))
        Ressac._step!(sched, 0.0)
        @test length(mock.sent) == 1
        bytes = mock.sent[1]
        @test String(bytes[1:7]) == "#bundle"
        size = ntoh(reinterpret(Int32, bytes[17:20])[1])
        m = Ressac.decode_message(bytes[21:20 + size])
        @test m.address == "/ressac/drone/set" && m.args[1] == "d4"
        d = Ressac.drone_get(:d4)
        @test d !== nothing && d.origin === :slot && d.values[:cutoff] == 500.0
    finally
        empty!(Ressac._DRONES)
        delete!(Ressac._SYNTH_REGISTRY, :tickdrone)
    end
end
