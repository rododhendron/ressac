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
    @test ("sustain" in m1.args)                           # durée : le défaut du synth
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
