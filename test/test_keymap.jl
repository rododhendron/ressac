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
    # action à deux arguments : reçoit l'événement
    Ressac.bind!(:t_global, "R", "avec evt"; action = (t, e) -> push!(hits, "R:" * string(e.char)))
    @test Ressac.dispatch!(layers, TKk.KeyEvent('R')) && hits[end] == "R:R"
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

@testset "keymap — hints / hint_text (barre de touches)" begin
    Ressac.clear_scope!(:t_bar); Ressac.clear_scope!(:t_bar_g)
    Ressac.bind!(:t_bar, ["e", "E"], "évaluer la ligne courante"; action = identity, short = "évaluer")
    Ressac.bind!(:t_bar, "x", "caché"; action = identity, hint = false)
    Ressac.bind!(:t_bar, "Space d", "slot"; action = identity)           # accord : which-key seulement
    Ressac.bind!(:t_bar, "z", "si vrai"; action = identity, when = t -> t)
    Ressac.bind!(:t_bar_g, "e", "global e (masqué par la couche pane)"; action = identity)
    Ressac.bind!(:t_bar_g, "?", "aide"; action = identity)
    h = Ressac.hints(((:t_bar, false), (:t_bar_g, false)))
    @test h == [("e", "évaluer"), ("?", "aide")]
    h2 = Ressac.hints(((:t_bar, true),))
    @test ("z", "si vrai") in h2
    @test Ressac.hints(((:t_bar, true),); prefix = "Space") == [("d", "slot")]
    txt = Ressac.hint_text(((:t_bar, false), (:t_bar_g, false)))
    @test txt == "e évaluer · ? aide"
    @test Ressac.hint_text(((:t_bar, false), (:t_bar_g, false)); max_width = 12) == "e évaluer"
    Ressac.clear_scope!(:t_bar); Ressac.clear_scope!(:t_bar_g)
end

@testset "couches et mixins — un vocabulaire déclaré une fois" begin
    @test Ressac.scope_layer(:global) === :global
    @test Ressac.scope_layer(:modal_lib) === :modal
    @test Ressac.scope_layer(:leader) === :transient && Ressac.scope_layer(:pane_mode) === :transient
    @test Ressac.scope_layer(:doc) === :pane && Ressac.scope_layer(:sculpt) === :pane
    @test_throws ArgumentError Ressac.scope!(:t_bad, "x"; layer = :nope)
    # scroll_nav : les mêmes touches partout, les variantes par options
    keys(scope) = Set(k for b in Ressac.bindings(scope) if b.action !== nothing for k in b.keys)
    base = Set(["j", "↓", "k", "↑", "PgDn", "Ctrl-d", "PgUp", "Ctrl-u", "g", "G"])
    @test base ⊆ keys(:doc) && base ⊆ keys(:wiki) && base ⊆ keys(:log) && base ⊆ keys(:tutorial)
    @test base ⊆ keys(:modal_text) && base ⊆ keys(:modal_help) && base ⊆ keys(:synthdoc)
    @test "d" in keys(:doc) && "u" in keys(:wiki) && !("d" in keys(:log))
    # list_nav
    for sc in (:modal_browse, :modal_lib, :modal_snippets, :modal_patterns, :modal_sccode, :modal_mixer, :modal_evolve)
        @test base ⊆ keys(sc)
    end
    # knob_nav
    knobs = Set(["j", "k", "h", "l", "→", "←", "=", "Tab", "S-Tab"])
    @test knobs ⊆ keys(:sculpt) && knobs ⊆ keys(:drone) && "0" in keys(:drone) && "L" in keys(:drone)
    # un mixin sur un scope de test
    Ressac.clear_scope!(:t_mix)
    mutable struct _TMix; sp::Tachikoma.ScrollPane; end
    Ressac.mixin_scroll_nav!(:t_mix, t -> t.sp)
    @test length(Ressac.bindings(:t_mix)) == 6
    t = _TMix(Ressac._scrollpane())
    Tachikoma.set_content!(t.sp, [string(i) for i in 1:50]); t.sp.last_area = Tachikoma.Rect(1, 1, 20, 5)
    @test Ressac.dispatch!(((:t_mix, t),), Tachikoma.KeyEvent('j'))
    @test t.sp.offset == 1
    @test Ressac.dispatch!(((:t_mix, t),), Tachikoma.KeyEvent('G'))
    @test t.sp.offset > 1
    @test Ressac.dispatch!(((:t_mix, t),), Tachikoma.KeyEvent('g'))
    @test t.sp.offset == 0
    @test !Ressac.dispatch!(((:t_mix, t),), Tachikoma.KeyEvent('k'))      # en haut : k indisponible
    Ressac.clear_scope!(:t_mix)
end

@testset "règle des couches — une touche de mode n'est jamais une touche d'une pane du mode" begin
    active_keys(scope) = Set(k for b in Ressac.bindings(scope) if b.action !== nothing for k in b.keys)
    for mode in (:play, :design, :explore)
        mk = active_keys(Symbol("mode_", mode))
        @test !isempty(mk)
        for scope in keys(Ressac._KEYMAP)
            Ressac.scope_layer(scope) === :pane || continue
            Ressac._scope_in_mode(scope, mode) || continue
            # :editor documente le moteur vim du texte ; qu'un geste de mode
            # passe avant une motion (t/T « jusqu'au caractère » dans DESIGN)
            # est le prix assumé, pas un conflit de registre
            scope === :editor && continue
            clash = intersect(mk, active_keys(scope))
            @test isempty(clash) || (println("conflit $mode / $scope : ", clash); false)
        end
    end
    # les trois modes partagent T/D (entendre, drone) là où ça a un sens, Espace = leader
    @test "Space" in active_keys(:mode_play) && "Space" in active_keys(:mode_design)
    @test "T" in active_keys(:mode_design) && "T" in active_keys(:mode_explore)
end

@testset "scopes par mode — déclarés une fois, l'aide « tout » et le wiki en dérivent" begin
    @test Ressac.scope_modes(:patterns) == (:play,) && Ressac.scope_modes(:explorer) == (:explore,)
    @test Ressac.scope_modes(:global) == (:play, :design, :explore)
    @test Ressac.scope_in_mode(:sculpt, :design) && Ressac.scope_in_mode(:sculpt, :explore) && !Ressac.scope_in_mode(:sculpt, :play)
    @test_throws ArgumentError Ressac.scope!(:t_bad2, "x"; modes = (:nope,))
    d = Ressac.scopes_for_mode(:design)
    @test d[1] === :mode_design && d[2] === :global
    @test :synth in d && :sculpt in d && :synthdoc in d && :modal_lib in d
    @test !(:patterns in d) && !(:explorer in d) && !(:tap in d)
    @test findfirst(==(:sculpt), d) < findfirst(==(:leader_synth), d) < findfirst(==(:modal_lib), d)   # panes, puis transitoires, puis modales
    md = Ressac.keys_wiki_markdown()
    @test occursin("## PLAY\n", md) && occursin("## DESIGN\n", md) && occursin("## EXPLORE\n", md) && occursin("## Partout\n", md)
    @test findfirst("### DESIGN — quelle que soit la pane", md)[1] < findfirst("### Sculpt", md)[1]
    @test findfirst("## Partout", md)[1] < findfirst("### Éditeur (patterns et synth)", md)[1]
end
