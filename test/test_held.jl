include(joinpath(@__DIR__, "helpers.jl"))
# Les événements longs — roadmap M1.
#
# Une requête rend ce qui COMMENCE dans la fenêtre. « Quelle valeur est en
# cours ? » est une autre question (`_held`) : un contrôle, un masque, un
# facteur posés avant la fenêtre valent encore dedans.

# Nombre d'événements par cycle, sur `n` cycles.
_per_cycle(p, n = 4) = [length(p(c // 1, (c + 1) // 1)) for c in 0:(n - 1)]
_vals(p, key, n = 4) = [ev.value[key] for c in 0:(n - 1) for ev in p(c // 1, (c + 1) // 1)]
# Le même pattern, privé de sa tenue exacte : `_held` retombe sur le repli.
_without_held(p::Pattern{T}) where {T} = Pattern{T}(p.query)
_arcs(evs) = sort!([(ev.start, ev.stop, ev.value) for ev in evs]; by = x -> (x[1], x[2], string(x[3])))

@testset "tenue — les événements longs" begin

    @testset "_held : ce qui recouvre la fenêtre, créneaux entiers" begin
        p = slow(4, p"a b")                          # a [0,2) · b [2,4)
        @test _arcs(Ressac._held(p, 1 // 1, 2 // 1)) == [(0 // 1, 2 // 1, :a)]
        @test _arcs(Ressac._held(p, 3 // 2, 5 // 2)) == [(0 // 1, 2 // 1, :a), (2 // 1, 4 // 1, :b)]
        @test isempty(p(1 // 1, 2 // 1))             # la requête d'attaque, elle, ne rend rien
        @test Ressac._value_at(p, 7 // 2) === :b
        @test Ressac._value_at(p"a ~", 3 // 4) === nothing
        # Un signal continu est échantillonné à l'instant demandé.
        @test Ressac._value_at(saw(), 1 // 4) ≈ 0.25 atol = 1e-3
    end

    @testset "la tenue exacte et le repli disent la même chose" begin
        pats = Any[pure(:x), p"a b c", p"<a b>/2", p"a/3 b", p"[a b]/4 c", p"a@3 b", p"<a b c>!2",
                   p"a(3,8)", p"{a b c}%4", slow(3, p"a b"), fast(3 // 2, p"a b c"),
                   early(1 // 3, slow(2, p"a b")), late(5 // 4, p"a b"),
                   stack(slow(2, p"a b"), p"c*3"), slow(5, stack(p"a", p"b c")),
                   p"0 1 2" + 1, Ressac._lift_to_control(slow(2, p"bd sn"))]
        for p in pats, (s, e) in ((0 // 1, 1 // 1), (1 // 1, 2 // 1), (5 // 2, 3 // 1),
                                  (7 // 3, 29 // 6), (11 // 1, 12 // 1), (-3 // 2, -1 // 1))
            @test _arcs(Ressac._held(p, s, e)) == _arcs(Ressac._held(_without_held(p), s, e))
            # et la requête d'attaque en est la partie qui commence dans la fenêtre
            @test _arcs(p(s, e)) == _arcs([ev for ev in Ressac._held(p, s, e) if s <= ev.start < e])
        end
    end

    @testset "contrôles : une valeur posée avant la fenêtre vaut encore" begin
        @test _per_cycle("bd*4" |> lpf(slow(4, p"400 2000"))) == [4, 4, 4, 4]
        @test _vals("bd*4" |> lpf(slow(4, p"400 2000")), :cutoff) == vcat(fill(400, 8), fill(2000, 8))
        @test _per_cycle("bd*4" |> lpf("<400 2000>/2")) == [4, 4, 4, 4]
        @test _vals("bd*4" |> lpf("<400 2000>/2"), :cutoff) == vcat(fill(400, 8), fill(2000, 8))
        # Un son sans rythme prend celui du contrôle — y compris quand le
        # contrôle dure plus d'un cycle.
        @test _per_cycle(:bd |> n("<0 3>/2")) == [1, 1, 1, 1]
        @test _vals(:bd |> n("<0 3>/2"), :n) == [0, 0, 3, 3]
        # Un signal continu est lu à l'attaque de chaque événement, pas une
        # fois par cycle.
        cut = _vals("bd*4" |> lpf(saw() |> range_pat(0, 100)), :cutoff, 1)
        @test issorted(cut) && length(unique(cut)) == 4
        # `both` : les deux côtés par leur tenue, un morceau par attaque.
        @test _per_cycle(slow(2, pure(:bd)) |> both(n("0 1"))) == [2, 2, 2, 2]
    end

    @testset "masque, facteur patterné, arithmétique" begin
        @test _per_cycle(mask(p"bd*4", slow(4, Ressac._as_bool_pattern("1 0")))) == [4, 4, 0, 0]
        @test _per_cycle("bd*2" |> fast("<1 2>/2")) == [2, 2, 4, 4]
        sum_pat = Ressac._mapvals(v -> parse(Int, String(v)), slow(2, p"1 2"), Int) +
                  Ressac._mapvals(v -> parse(Int, String(v)), p"10 20", Int)
        @test [ev.value for c in 0:1 for ev in sum_pat(c // 1, (c + 1) // 1)] == [11, 21, 12, 22]
    end

    @testset "découpes : chop, ply, bend sur un événement long" begin
        @test _per_cycle(Ressac.chop(8, slow(2, pure(:amen))), 2) == [4, 4]
        b = [ev.value[:begin] for c in 0:1 for ev in Ressac.chop(8, slow(2, pure(:amen)))(c // 1, (c + 1) // 1)]
        @test b ≈ Float32.((0:7) ./ 8)
        @test _per_cycle(ply(4, slow(2, pure(:bd))), 2) == [2, 2]
        # ply ne rogne plus : chaque répétition garde son créneau.
        @test all(ev -> ev.stop - ev.start == 1 // 2, ply(4, slow(2, pure(:bd)))(0 // 1, 2 // 1))
        @test [ev.value[:note] for ev in ("a*4" |> bend(p"0 50"))(0 // 1, 1 // 1)] == [0.0, 0.0, 0.5, 0.5]
    end

    @testset "rev : un événement à cheval est réfléchi, jamais pris pour une attaque" begin
        got = [(ev.start, ev.value) for ev in rev(slow(2, p"a b c"))(0 // 1, 2 // 1)]
        @test got == [(1 // 3, :a), (1 // 1, :c), (5 // 3, :b)]
        # Sur des événements d'un cycle ou moins, rien ne change.
        @test [ev.value for ev in rev(p"a b c")(0 // 1, 1 // 1)] == [:c, :b, :a]
        @test _arcs(rev(rev(p"a b [c d]"))(0 // 1, 1 // 1)) == _arcs(p"a b [c d]"(0 // 1, 1 // 1))
    end

    @testset "à travers le scheduler : chaque attaque part une fois" begin
        mock = MockOSCClient()
        s = Scheduler(mock; cps = 1.0); s.t_start = 0.0
        set_pattern!(s, :d1, "bd*4" |> lpf("<400 2000>/2"))
        for t in 0.0:0.05:3.9; Ressac._step!(s, t); end
        Ressac._step!(s, 3.95)
        @test length(mock.sent) == 16
    end
end

@testset "mini-notation — cas limites (M3, M6)" begin
    v(str, r = 0:0) = [String(ev.value) for c in r for ev in parse_minino(str)(c // 1, (c + 1) // 1)]

    @testset "`<a b>*2` avance dans l'alternance" begin
        @test v("<bd sn>*2", 0:1) == ["bd", "sn", "bd", "sn"]
        @test v("<bd sn>*2") == [String(ev.value) for ev in fast(2, p"<bd sn>")(0 // 1, 1 // 1)]
        @test v("<0 2 4>*8") == ["0", "2", "4", "0", "2", "4", "0", "2"]
        @test v("[<a b>*2 c]", 0:1) == ["a", "b", "c", "a", "b", "c"]
        @test v("<a b>!2 c", 0:1) == ["a", "a", "c", "b", "b", "c"]       # `!` réplique, n'accélère pas
    end

    @testset "alternances imbriquées, pondérées, empilées" begin
        @test v("<a <b c>>", 0:3) == ["a", "b", "a", "c"]
        # `a@3` tient trois cycles d'un seul tenant.
        @test [(ev.start, ev.stop, ev.value) for ev in p"<a@3 b>"(0 // 1, 8 // 1)] ==
              [(0 // 1, 3 // 1, :a), (3 // 1, 4 // 1, :b), (4 // 1, 7 // 1, :a), (7 // 1, 8 // 1, :b)]
        @test [(ev.start, ev.stop, ev.value) for ev in p"<a _ b>"(0 // 1, 3 // 1)] ==
              [(0 // 1, 2 // 1, :a), (2 // 1, 3 // 1, :b)]
        @test Ressac._value_at(p"<a@3 b>", 5 // 2) === :a
        @test v("<a b, c d e>", 0:3) == ["a", "c", "b", "d", "a", "e", "b", "c"]
        @test_throws ArgumentError parse_minino("<>")
        @test_throws ArgumentError parse_minino("<a b")
    end

    @testset "un nombre détaché est un pas, pas un argument" begin
        @test v("0 ! 3") == ["0", "0", "3"]
        @test v("0! 3") == ["0", "0", "3"]
        @test v("bd!3 sn") == ["bd", "bd", "bd", "sn"]
        @test v("bd !3 sn") == ["bd", "bd", "bd", "sn"]
        @test v("bd ! ! sn") == ["bd", "bd", "bd", "sn"]
        # `0? 3` : deux pas ; le 3 n'est pas une probabilité (qui rendait tout muet).
        @test all(c -> last(v("0? 3", c:c)) == "3", 0:20)
        @test any(c -> length(v("0? 3", c:c)) == 2, 0:20) && any(c -> length(v("0? 3", c:c)) == 1, 0:20)
        @test all(c -> isempty(v("bd?1", c:c)), 0:10)
    end

    @testset "`|` : chaque occurrence tire pour soi" begin
        picks = [v("[a|b] [a|b] [a|b] [a|b]", c:c) for c in 0:30]
        @test any(p -> length(unique(p)) == 2, picks)        # pas toujours le même choix partout
        @test picks == [v("[a|b] [a|b] [a|b] [a|b]", c:c) for c in 0:30]   # mais reproductible
        stacked = [v("[a|b, a|b]", c:c) for c in 0:30]
        @test any(p -> length(unique(p)) == 2, stacked)
        @test any(p -> length(unique(p)) == 2, [v("[a|b]*4", c:c) for c in 0:30])
    end

    @testset "notation scientifique" begin
        @test v("1e3 2e-2 1.5e2") == ["1000.0", "0.02", "150.0"]
        @test v("e3 1 e") == ["e3", "1", "e"]                 # un nom de note reste un nom
        @test ("bd" |> lpf("1e3"))(0 // 1, 1 // 1)[1].value[:cutoff] == 1000.0
    end

    @testset "rythmes euclidiens : Bjorklund, comme Tidal" begin
        show_e(k, n) = join(b ? "x" : "." for b in Ressac._euclidean_pulses(k, n))
        # Les rythmes de référence de Toussaint, dans la rotation de Tidal.
        @test show_e(3, 8) == "x..x..x."       # tresillo
        @test show_e(5, 8) == "x.xx.xx."       # cinquillo
        @test show_e(2, 5) == "x.x.."
        @test show_e(3, 4) == "xxx."           # Bjorklund s'arrête là ; Toussaint le note x.xx (une rotation)
        @test show_e(3, 7) == "x.x.x.."
        @test show_e(4, 9) == "x.x.x.x.."
        @test show_e(5, 12) == "x..x.x..x.x."
        @test show_e(7, 16) == "x..x.x.x..x.x.x."
        @test show_e(0, 4) == "...." && show_e(4, 4) == "xxxx" && show_e(9, 4) == "xxxx"
        @test show_e(-3, 8) == ".xx.xx.x"      # négatif : l'inverse
        for n in 1:16, k in 0:n
            @test count(Ressac._euclidean_pulses(k, n)) == k
        end
        # Un nombre de pas littéral nul se refuse à l'évaluation ; un
        # argument patterné qui y tombe fait un cycle de silence.
        @test_throws ArgumentError parse_minino("bd(3,0)")
        @test [length(p"bd(3,<8 0>)"(c // 1, (c + 1) // 1)) for c in 0:3] == [3, 0, 3, 0]
        @test length(p"bd(-3,8)"(0 // 1, 1 // 1)) == 5
    end
end

@testset "un pattern et sa version transformée (M2, M5)" begin
    n_ctl(p, c) = count(ev -> get(ev.value, :gain, nothing) == 0.5, p(c // 1, (c + 1) // 1))

    @testset "`f` peut changer le type : every, lastOf, whenmod, sometimesBy, chunk, off" begin
        bd = p"bd*4"
        g = gain(0.5)
        @test [n_ctl(every(2, g, bd), c) for c in 0:3] == [4, 0, 4, 0]
        @test [n_ctl(lastOf(2, g, bd), c) for c in 0:3] == [0, 4, 0, 4]
        @test [n_ctl(whenmod(4, 2, g, bd), c) for c in 0:3] == [0, 0, 4, 4]
        @test [n_ctl(sometimesBy(1.0, g, bd), c) for c in 0:1] == [4, 4]
        @test [n_ctl(sometimesBy(0.0, g, bd), c) for c in 0:1] == [0, 0]
        @test [n_ctl(chunk(4, g, bd), c) for c in 0:3] == [1, 1, 1, 1]
        @test [n_ctl(chunkBack(4, g, bd), c) for c in 0:3] == [1, 1, 1, 1]
        o = off(1 // 8, g, bd)
        @test length(o(0 // 1, 1 // 1)) == 8 && n_ctl(o, 0) == 4
        # Formes au pipe, et les types restent ceux d'avant quand `f` les garde.
        @test (bd |> every(2, fast(2))) isa Pattern{Symbol}
        @test (bd |> every(2, gain(0.5))) isa Ressac.ControlPattern
        @test length((bd |> every(2, fast(2)))(0 // 1, 1 // 1)) == 8
    end

    @testset "`f(p)` est construit une fois, à la construction" begin
        calls = Ref(0)
        f = p -> (calls[] += 1; fast(2, p))
        for build in (p -> every(2, f, p), p -> sometimesBy(0.5, f, p), p -> chunk(4, f, p),
                      p -> whenmod(4, 2, f, p), p -> off(1 // 8, f, p), p -> lastOf(3, f, p))
            calls[] = 0
            q = build(p"bd sn")
            @test calls[] == 1
            for c in 0:7; q(c // 1, (c + 1) // 1); end
            @test calls[] == 1
        end
        # Une erreur dans `f` se lit à l'évaluation, pas dans le scheduler.
        @test_throws ErrorException sometimesBy(0.5, p -> error("non"), p"bd")
    end

    @testset "tirages : reproductibles, décorrélés par `seed`" begin
        p = p"bd*16"
        n(q) = sum(length(q(c // 1, (c + 1) // 1)) for c in 0:9)
        once = degradeBy(0.5, p)
        @test n(once) == n(degradeBy(0.5, p))                             # reproductible
        @test n(degradeBy(0.5, once)) == n(once)                          # même grille, même tirage (comme Tidal)
        twice = degradeBy(0.5, once; seed = 1)
        @test n(twice) < n(once) && n(twice) > 0                          # un autre tirage enlève encore
        @test n(degradeBy(0.5, p)) + n(unDegradeBy(0.5, p)) == 160        # compléments, même seed
        @test n(degradeBy(0.5, p; seed = 3)) + n(unDegradeBy(0.5, p; seed = 3)) == 160
        fired(q) = [length(q(c // 1, (c + 1) // 1)) == 32 for c in 0:39]
        a = fired(sometimes(fast(2), p)); b = fired(sometimes(fast(2), p; seed = 2))
        @test a == fired(sometimes(fast(2), p)) && a != b
        @test any(a) && !all(a)
    end

end

@testset "empilement, variantes, chaînes par cycle (M7, M8)" begin
    cnt(p) = length(p(0 // 1, 1 // 1))

    @testset "stack : forme publique, forme au pipe, usage interne" begin
        @test cnt(stack(p"bd*4", p"hh*8")) == 12
        @test stack(p"bd*4", p"hh*8") isa Pattern{Symbol}
        # Types mêlés, chaînes, noms : tout monte au même type.
        mixed = stack(p"bd*4", "hh*8" |> gain(0.6), :cp)
        @test mixed isa Ressac.ControlPattern && cnt(mixed) == 13
        # Au pipe.
        @test cnt(p"bd*4" |> stack(p"hh*8")) == 12
        @test cnt("bd*4" |> stack("hh*8" |> gain(0.6))) == 12
        # Un seul élément en interne : un pattern, pas une fonction.
        @test layer([rev], p"bd sn") isa Pattern
        @test cnt(layer([rev], p"bd sn")) == 2
        @test cnt(layer([rev, fast(2)], p"bd sn")) == 6
        @test Ressac._stack([p"bd"]) isa Pattern
        @test timeCat([(1, "bd*4")]) isa Pattern
        @test stut(1, 0.5, 1 // 8, "bd") isa Pattern
        @test_throws ArgumentError Ressac._stack(Pattern{Symbol}[])
        # La tenue traverse un empilement.
        @test length(Ressac._held(stack(slow(2, p"a b"), p"c"), 1 // 2, 1 // 1)) == 2
    end

    @testset "`nom:3` : un seul lecteur du suffixe" begin
        @test Ressac._split_variant(Symbol("sn:3")) == (:sn, 3)
        @test Ressac._split_variant(:sn) == (:sn, nothing)
        @test Ressac._split_variant(Symbol("bd:x")) == (Symbol("bd:x"), nothing)
        @test Ressac._symbol_to_control_map(Symbol("sn:3")) == Ressac.ControlMap(:s => :sn, :n => 3)
        # Un suffixe non numérique ne lève plus à la requête : il reste dans le nom.
        ev = only(("bd:x" |> gain(1))(0 // 1, 1 // 1))
        @test ev.value[:s] === Symbol("bd:x") && !haskey(ev.value, :n)
        @test Ressac.event_to_osc(ev; cps = 1.0) isa Ressac.OSCMessage
    end

    @testset "walk et markov : une fois calculés, plus rejoués" begin
        calls = Ref(0)
        ch = Ressac._CycleChain(0, (x, c) -> (calls[] += 1; x + c))
        @test Ressac._chain_at(ch, 0) == 0 && Ressac._chain_at(ch, -5) == 0
        @test Ressac._chain_at(ch, 5) == 0 + 0 + 1 + 2 + 3 + 4
        @test calls[] == 5
        Ressac._chain_at(ch, 5); Ressac._chain_at(ch, 3)
        @test calls[] == 5                                   # rien n'est recalculé
        @test Ressac._chain_at(ch, 6) == 15 && calls[] == 6  # seulement le pas manquant

        val(p, c) = p(Rational{Int64}(c), Rational{Int64}(c + 1))[1].value
        w = walk(0.1)
        seq1 = [val(w, c) for c in 0:50]
        @test seq1 == [val(walk(0.1), c) for c in 0:50]      # reproductible
        @test [val(w, c) for c in 50:-1:0] == reverse(seq1)  # quel que soit l'ordre des requêtes
        @test all(0 .<= seq1 .<= 1) && length(unique(seq1)) > 10
        @test all(abs.(diff(seq1)) .<= 0.1 + 1e-9)
        @test val(walk(0.1), 100_000) isa Float64            # loin dans la session, sans exploser

        mk = markov([[0, 1.0, 0], [0, 0, 1.0], [1.0, 0, 0]], [:a, :b, :c])
        @test [val(mk, c) for c in 0:5] == [:a, :b, :c, :a, :b, :c]
        # Un événement par cycle, entier, rendu avec son attaque seulement.
        @test isempty(mk(1 // 2, 1 // 1))
        ev = only(mk(3 // 1, 7 // 2))
        @test (ev.start, ev.stop) == (3 // 1, 4 // 1)
        pick = choose([:x, :y, :z])
        @test isempty(pick(1 // 2, 1 // 1)) && only(pick(2 // 1, 3 // 1)).stop == 3 // 1
    end
end
