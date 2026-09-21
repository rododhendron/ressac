# Routage OSC : variantes « sn:3 », effets SuperDirt sur un synth utilisateur.
using Test
using Ressac

@testset "routage — « sn:3 » devient s=sn n=3 (Symbol et ControlMap)" begin
    @test Ressac._split_variant(Symbol("sn:3")) == (:sn, 3)
    @test Ressac._split_variant(:sn) == (:sn, nothing)
    @test Ressac._split_variant(Symbol("bd:x")) == (Symbol("bd:x"), nothing)
    msg = Ressac.event_to_osc(Ressac.Event(0//1, 1//1, Symbol("sn:3")))
    @test msg.address == "/dirt/play"
    @test msg.args == Any["s", "sn", "n", 3]
    p = p"sn:3 hh" |> gain(0.5)
    evs = p(0//1, 1//1)
    m1 = Ressac.event_to_osc(evs[1])
    @test m1.address == "/dirt/play"
    i = findfirst(==("s"), m1.args); @test m1.args[i + 1] == "sn"
    j = findfirst(==("n"), m1.args); @test m1.args[j + 1] == 3
    # un n explicite gagne sur la variante
    q = (p"sn:3" |> n(7))(0//1, 1//1)[1]
    m2 = Ressac.event_to_osc(q); k = findfirst(==("n"), m2.args)
    @test m2.args[k + 1] == 7
end

@testset "routage — synth utilisateur : direct sans effet, SuperDirt avec un effet" begin
    Ressac.register_synth!(Ressac.SynthEntry(:monson, "user-dsl",
        Dict{String,Any}("params" => Dict{String,Any}("freq" => 220, "sustain" => 0.5))))
    plain = (pure(:monson) |> gain(0.8))(0//1, 1//1)[1]
    m0 = Ressac.event_to_osc(plain)
    @test m0.address == "/ressac/play"                     # aucun effet → défauts du SynthDef
    fx = (pure(:monson) |> n(3) |> fast(2) |> lpf(400))(0//1, 1//2)[1]
    m1 = Ressac.event_to_osc(fx)
    @test m1.address == "/dirt/play"                       # lpf → SuperDirt applique l'effet
    s = findfirst(==("s"), m1.args); @test m1.args[s + 1] == "monson"
    @test "lpf" in m1.args
    @test !("freq" in m1.args)                             # n pilote la hauteur : pas de freq injectée
    @test !("sustain" in m1.args)                          # durée : SuperDirt la déduit de delta
    fx2 = (pure(:monson) |> room(0.3))(0//1, 1//1)[1]
    m2 = Ressac.event_to_osc(fx2)
    f = findfirst(==("freq"), m2.args); @test m2.args[f + 1] == 220   # sans n : freq du synth
    delete!(Ressac._SYNTH_REGISTRY, :monson)
end

@testset "routage — _dsl_params_from_text lit les défauts d'un @synth" begin
    @test Ressac._dsl_params_from_text("@synth :x (freq=110, sustain=2.5, cutoff=800) saw(:freq)") ==
          Dict{String,Any}("freq" => 110, "sustain" => 2.5, "cutoff" => 800)
    @test Ressac._dsl_params_from_text("SynthDef(\\x, { })") == Dict{String,Any}()
end

@testset "routage — cps / cycle / delta envoyés comme Tidal, sustain des synths directs" begin
    evs = (pure(:superpiano) |> n("[0 3] 7"))(0//1, 1//1)
    m = Ressac.event_to_osc(evs[2]; cps = 0.5)
    @test m.args[end-5:end] == ["cps", 0.5f0, "cycle", 0.25f0, "delta", 0.5f0]   # 1/4 cycle à 0,5 cps = 0,5 s
    @test Ressac.event_to_osc(evs[3]; cps = 0.5).args[end] == 1.0f0
    @test !("delta" in Ressac.event_to_osc(evs[2]).args)                      # sans cps : rien d'ajouté
    sym = Ressac.event_to_osc(Ressac.Event(0//1, 1//4, Symbol("sn:3")); cps = 1.0)
    @test sym.args == ["s", "sn", "n", 3, "cps", 1.0f0, "cycle", 0.0f0, "delta", 0.25f0]

    Ressac.register_synth!(Ressac.SynthEntry(:monson, "user-dsl",
        Dict{String,Any}("params" => Dict{String,Any}("freq" => 220, "sustain" => 0.5))))
    direct = Ressac.event_to_osc((pure(:monson) |> n("[0 3] 7"))(0//1, 1//1)[1]; cps = 0.5)
    @test direct.address == "/ressac/play" && direct.args[1:2] == ["monson", "freq"]   # n → freq (route directe)
    @test isapprox(direct.args[3], 261.63; atol = 0.01)
    @test direct.args[4:5] == ["sustain", 0.5f0]
    fixed = Ressac.event_to_osc((pure(:monson) |> sustain(3))(0//1, 1//1)[1]; cps = 0.5)
    @test fixed.args == ["monson", "sustain", 3]                              # sustain explicite : intact
    bare = Ressac.event_to_osc(Ressac.Event(0//1, 1//4, :monson); cps = 0.5)
    @test bare.args == ["monson", "sustain", 0.5f0]
    @test Ressac.event_to_osc(Ressac.Event(0//1, 1//4, :monson)).args == ["monson"]   # sans cps : défauts
    delete!(Ressac._SYNTH_REGISTRY, :monson)
    Ressac.register_synth!(Ressac.SynthEntry(:nosus, "user-dsl",
        Dict{String,Any}("params" => Dict{String,Any}("freq" => 220))))
    @test Ressac.event_to_osc(Ressac.Event(0//1, 1//4, :nosus); cps = 0.5).args == ["nosus"]  # pas de param sustain
    delete!(Ressac._SYNTH_REGISTRY, :nosus)
end

@testset "routage — une chaîne de contrôle à un seul jeton vaut un scalaire" begin
    @test Ressac._string_control_value("c") === :c
    @test Ressac._string_control_value("bd:3") === Symbol("bd:3")
    @test Ressac._string_control_value("0.5") === Symbol("0.5")
    @test Ressac._string_control_value("[0 3]") isa Pattern
    @test Ressac._string_control_value("<0 3>") isa Pattern
    @test Ressac._string_control_value("0 _") isa Pattern
    # un événement de deux cycles n'est plus découpé par unit("c")
    @test length((slow(2, pure(:bd)) |> unit("c"))(0//1, 2//1)) == 1
end

@testset "routage — synth direct : n / note / octave / midinote deviennent freq" begin
    Ressac.register_synth!(Ressac.SynthEntry(:arpdriver, "user-dsl",
        Dict{String,Any}("params" => Dict{String,Any}("freq" => 220, "sustain" => 0.12))))
    kv(m) = Dict(m.args[i] => m.args[i + 1] for i in 2:2:length(m.args) - 1)
    m = Ressac.event_to_osc((pure(:arpdriver) |> n("0 4 7"))(0//1, 1//1)[2])
    @test m.address == "/ressac/play" && m.args[1] == "arpdriver"
    @test kv(m)["freq"] ≈ 329.63 atol = 0.01                      # n 4 → mi 5 (MIDI 64)
    @test !haskey(kv(m), "n")
    @test kv(Ressac.event_to_osc((pure(:arpdriver) |> note("c e"))(0//1, 1//1)[1]))["freq"] ≈ 261.63 atol = 0.01
    @test kv(Ressac.event_to_osc((pure(:arpdriver) |> n(0) |> octave(4))(0//1, 1//1)[1]))["freq"] ≈ 130.81 atol = 0.01
    @test kv(Ressac.event_to_osc((pure(:arpdriver) |> midinote(69))(0//1, 1//1)[1]))["freq"] ≈ 440.0
    @test kv(Ressac.event_to_osc((pure(:arpdriver) |> n(12) |> freq(100))(0//1, 1//1)[1]))["freq"] == 100   # freq explicite
    @test !haskey(kv(Ressac.event_to_osc((pure(:arpdriver) |> gain(0.5))(0//1, 1//1)[1])), "freq")   # sans hauteur : défaut du SynthDef
    # les noms de notes et les accords passent aussi
    chord = Ressac.event_to_osc.((pure(:arpdriver) |> n("c'maj"))(0//1, 1//1))
    @test isapprox([kv(x)["freq"] for x in chord], [261.63, 329.63, 392.0]; atol = 0.01)
    delete!(Ressac._SYNTH_REGISTRY, :arpdriver)
end
