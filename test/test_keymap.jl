# Registre de bindings — tests purs (aucune app, aucune pane).
using Test
using Ressac
import Tachikoma
const TKk = Tachikoma

@testset "keymap — keyname canonique" begin
    @test Ressac.keyname(TKk.KeyEvent('e')) == "e"
    @test Ressac.keyname(TKk.KeyEvent('?')) == "?"
    @test Ressac.keyname(TKk.KeyEvent(' ')) == "Space"
    @test Ressac.keyname(TKk.KeyEvent(:tab)) == "Tab"
    @test Ressac.keyname(TKk.KeyEvent(:backtab)) == "S-Tab"
    @test Ressac.keyname(TKk.KeyEvent(:escape)) == "Esc"
    @test Ressac.keyname(TKk.KeyEvent(:enter)) == "Enter"
    @test Ressac.keyname(TKk.KeyEvent('\r')) == "Enter"
    @test Ressac.keyname(TKk.KeyEvent(:down)) == "↓"
    @test Ressac.keyname(TKk.KeyEvent(:pagedown)) == "PgDn"
    @test Ressac.keyname(TKk.KeyEvent(:ctrl, 'w')) == "Ctrl-w"
    @test Ressac.keyname(TKk.KeyEvent(:ctrl, 'W')) == "Ctrl-w"
    @test Ressac.keyname(TKk.KeyEvent(:ctrl, '\0')) == ""      # modificateur seul
end

@testset "keymap — bind!/bindings/dispatch!" begin
    Ressac.clear_scope!(:t_scope); Ressac.clear_scope!(:t_global)
    Ressac.scope!(:t_scope, "Scope de test")
    hits = String[]
    Ressac.bind!(:t_scope, "e", "évaluer"; action = t -> push!(hits, "e:$t"), group = :eval)
    Ressac.bind!(:t_scope, ["j", "↓"], "descendre"; action = t -> push!(hits, "j"), group = :nav)
    Ressac.bind!(:t_scope, "x", "seulement si pair"; action = t -> push!(hits, "x"),
                 when = t -> iseven(t))
    Ressac.bind!(:t_scope, "w", "motion vim (doc seule)")               # sans action
    Ressac.bind!(:t_global, "e", "global e"; action = t -> push!(hits, "ge"))
    Ressac.bind!(:t_global, "+", "nudge"; action = t -> push!(hits, "+"), repeat = true)

    layers = [(:t_scope, 2), (:t_global, 0)]
    @test Ressac.scope_title(:t_scope) == "Scope de test"
    @test length(Ressac.bindings(:t_scope)) == 4
    # ordre des couches : le scope focalisé gagne sur le global
    @test Ressac.dispatch!(layers, TKk.KeyEvent('e')) == true
    @test hits == ["e:2"]
    # synonyme
    @test Ressac.dispatch!(layers, TKk.KeyEvent(:down)) == true
    @test hits[end] == "j"
    # prédicat when : faux → tombe au global (absent) → false
    @test Ressac.dispatch!([(:t_scope, 3)], TKk.KeyEvent('x')) == false
    @test Ressac.dispatch!([(:t_scope, 4)], TKk.KeyEvent('x')) == true
    # binding sans action ne consomme pas
    @test Ressac.dispatch!(layers, TKk.KeyEvent('w')) == false
    # touche inconnue
    @test Ressac.dispatch!(layers, TKk.KeyEvent('Z')) == false
    # key_repeat : seulement les bindings repeat
    rep_e = TKk.KeyEvent(:char, 'e', TKk.key_repeat)
    rep_p = TKk.KeyEvent(:char, '+', TKk.key_repeat)
    n0 = length(hits)
    @test Ressac.dispatch!(layers, rep_e) == false
    @test Ressac.dispatch!(layers, rep_p) == true
    @test length(hits) == n0 + 1
    # re-bind du même (touches, label) remplace au lieu de dupliquer
    Ressac.bind!(:t_scope, "e", "évaluer"; action = t -> push!(hits, "e2"))
    @test count(b -> b.keys == ["e"], Ressac.bindings(:t_scope)) == 1
    @test Ressac.dispatch!(layers, TKk.KeyEvent('e')) && hits[end] == "e2"
end

@testset "keymap — accords à préfixe et which-key" begin
    Ressac.clear_scope!(:t_leader)
    got = String[]
    Ressac.bind!(:t_leader, "Space d", "slot"; action = t -> push!(got, "d"))
    Ressac.bind!(:t_leader, "Space g", "gain"; action = t -> push!(got, "g"))
    Ressac.bind!(:t_leader, "Space ?", "aide"; action = t -> push!(got, "?"), group = :help)
    Ressac.bind!(:t_leader, "z", "pas un accord"; action = t -> push!(got, "z"))
    # sans préfixe, "d" ne matche pas "Space d"
    @test Ressac.dispatch!([(:t_leader, 0)], TKk.KeyEvent('d')) == false
    @test Ressac.dispatch!([(:t_leader, 0)], TKk.KeyEvent('d'); prefix = "Space") == true
    @test got == ["d"]
    wk = Ressac.prefix_bindings(:t_leader, "Space")
    @test [k for (k, _) in wk] == ["d", "g", "?"]
    @test all(b.scope === :t_leader for (_, b) in wk)
    @test Ressac.lookup(:t_leader, "Space g").label == "gain"
    @test Ressac.lookup(:t_leader, "Space q") === nothing
end

@testset "keymap — available / help_sections / conflits" begin
    Ressac.clear_scope!(:t_help)
    Ressac.scope!(:t_help, "Aide test")
    Ressac.bind!(:t_help, "a", "toujours"; action = identity, group = :nav)
    Ressac.bind!(:t_help, "b", "caché de la barre"; action = identity, group = :nav, hint = false)
    Ressac.bind!(:t_help, "c", "si vrai"; action = identity, when = t -> t, group = :edit)
    av = Ressac.available(:t_help, false)
    @test [b.keys[1] for b in av] == ["a"]
    av2 = Ressac.available(:t_help, true; hint_only = false)
    @test [b.keys[1] for b in av2] == ["a", "b", "c"]
    secs = Ressac.help_sections([:t_help, :t_absent]; targets = Dict(:t_help => false))
    @test length(secs) == 1                       # scope vide ignoré
    @test secs[1].title == "Aide test"
    @test [g.title for g in secs[1].groups] == ["Naviguer", "Éditer"]
    @test secs[1].groups[2].rows[1].dim == true   # `c` indisponible → grisé
    @test secs[1].groups[1].rows[1].keys == "a"
    # conflit : deux actions inconditionnelles sur la même touche
    Ressac.clear_scope!(:t_conf)
    Ressac.bind!(:t_conf, "k", "un"; action = identity)
    Ressac.bind!(:t_conf, "k", "deux"; action = identity)
    @test any(occursin("t_conf", c) for c in Ressac.keymap_conflicts())
    Ressac.clear_scope!(:t_conf)
    # avec prédicat distinct, pas de conflit signalé
    Ressac.bind!(:t_conf, "k", "un"; action = identity, when = t -> t)
    Ressac.bind!(:t_conf, "k", "deux"; action = identity)
    @test !any(occursin("t_conf", c) for c in Ressac.keymap_conflicts())
    for s in (:t_scope, :t_global, :t_leader, :t_help, :t_conf); Ressac.clear_scope!(s); end
end
