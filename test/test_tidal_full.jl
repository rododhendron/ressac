# Couverture complète du vocabulaire Tidal (core_tidal.jl) + sucre `@d1 n "0 2"`.
using Test
using Ressac

vals(p, s = 0//1, e = 1//1) = [ev.value for ev in sort(p(s, e); by = ev -> ev.start)]
starts(p, s = 0//1, e = 1//1) = [ev.start for ev in sort(p(s, e); by = ev -> ev.start)]
nv(p, s = 0//1, e = 1//1) = [get(ev.value, :n, nothing) for ev in sort(p(s, e); by = ev -> ev.start)]
sv(p, s = 0//1, e = 1//1) = [get(ev.value, :s, nothing) for ev in sort(p(s, e); by = ev -> ev.start)]
percycle(p, n) = [vals(p, c // 1, (c + 1) // 1) for c in 0:(n - 1)]

# ---------------------------------------------------------------------------
@testset "sucre Tidal — @d1 n \"0 2\" |> s \"bd\" |> fast 2" begin
    sugar(args...) = Ressac._tidal_sugar(Any[args...])
    # n "1 2 3" |> fast 2 |> gain 0.8  →  (n, "1 2 3" |> fast, 2 |> gain, 0.8)
    ex = sugar(:n, :("1 2 3" |> fast), :(2 |> gain), 0.8)
    @test string(ex) == "(Ressac._lift_head(n(\"1 2 3\")) |> fast(2)) |> gain(0.8)"
    @test string(sugar(:every, 4, :rev, "bd hh")) == "Ressac._lift_head((every(4, rev))(\"bd hh\"))"
    @test string(sugar(:("bd hh" |> every), 4, :rev)) == "Ressac._lift_head(\"bd hh\") |> every(4, rev)"
    # une expression classique reste inchangée (à part _lift_head, identité)
    @test string(sugar(:(:bd |> n("0 1")))) == "Ressac._lift_head(:bd) |> n(\"0 1\")"

    pat = eval(sugar(:n, :("0 2" |> s), "bd"))
    @test nv(pat) == [0, 2] && sv(pat) == [:bd, :bd]
    pat = eval(sugar(:s, :("bd*2" |> n), "<0 3>"))
    @test nv(pat) == [0, 0] && nv(pat, 1//1, 2//1) == [3, 3]
    pat = eval(sugar(:every, 4, :rev, "bd hh"))
    @test vals(pat) == [:hh, :bd] && vals(pat, 1//1, 2//1) == [:bd, :hh]
    pat = eval(sugar(:("bd hh" |> fast), 2))
    @test vals(pat) == [:bd, :hh, :bd, :hh]

    # contrôle seul : son par défaut
    pat = eval(sugar(:n, "0 2"))
    @test nv(pat) == [0, 2] && sv(pat) == [Ressac._DEFAULT_SOUND[], Ressac._DEFAULT_SOUND[]]
    @test sv(Ressac._lift_head(n("0"))) == [Ressac._DEFAULT_SOUND[]]
    @test Ressac._lift_head(p"bd") isa Pattern

    # la macro elle-même expanse vers _route_to_slot!
    mex = @macroexpand @d1 n "0 2" |> s "bd" |> fast 2
    @test occursin("_route_to_slot!", string(mex))
    @test occursin("_lift_head", string(mex))
    @test occursin("fast(2)", string(mex))
    @test string(@macroexpand @d1) == "Ressac._route_to_slot!(:d1)"
    @test_throws ArgumentError Ressac._tidal_sugar(Any[:(a |> b), :|>])
end

@testset "contrôles Tidal — s / sound / up / begin_ / end_ / unit / cut / nudge" begin
    @test sv(Ressac._lift_head(s("bd:3 sn"))) == [Symbol("bd:3"), :sn]
    @test sound === s
    @test [ev.value[:note] for ev in (Ressac._lift_head(up("c e")))(0//1, 1//1)] == [0, 4]
    evs = (:amen |> begin_(0.25) |> end_(0.5))(0//1, 1//1)
    @test evs[1].value[:begin] == 0.25 && evs[1].value[:end] == 0.5
    @test (:bd |> unit("c"))(0//1, 1//1)[1].value[:unit] === :c
    @test (:bd |> cut(1))(0//1, 1//1)[1].value[:cut] == 1
    @test (:bd |> nudge(0.1))(0//1, 1//1)[1].value[:nudge] == 0.1
    @test (:bd |> orbit(1))(0//1, 1//1)[1].value[:orbit] == 1
    # sn:3 posé par s() est bien envoyé comme s=sn n=3
    msg = Ressac.event_to_osc(Ressac.Event{Ressac.ControlMap}(0//1, 1//4, Ressac.ControlMap(:s => Symbol("sn:3"))))
    @test msg.args[1:4] == ["s", "sn", "n", 3]
end

@testset "arithmétique |+| |*| |%| — mini-notation, chaînes, ControlPattern" begin
    @test vals(p"0 2" + 12) == [12, 14]
    @test vals(12 + p"0 2") == [12, 14]
    @test vals(p"0 2" + "<0 12>") == [0, 2]
    @test vals(p"0 2" + "<0 12>", 1//1, 2//1) == [12, 14]
    @test vals("1 2" * p"3") == [3, 6]
    @test vals(p"7 8" % 3) == [1, 2]
    @test vals(mod(p"7 -1", 3)) == [1, 2]
    @test vals(p"0 2" - 1) == [-1, 1]
    @test vals(p"1 2" / 2) == [0.5, 1.0]
    # deux ControlPatterns : structure des deux côtés, clés numériques additionnées
    cp = (:bd |> n("0 2")) + (:x |> n(12))
    @test nv(cp) == [12, 14] && sv(cp) == [:bdx, :bdx]   # `:s` se concatène sous +
    @test [ev.value[:gain] for ev in ((:bd |> gain(0.5)) * 2)(0//1, 1//1)] == [1.0]
    @test (p"0 2" + 1) isa Pattern && sv(n(p"0 2" + 12)(pure(:bd))) == [:bd, :bd]
    @test nv(:bd |> n(p"0 2" + 12)) == [12, 14]
    @test_throws ArgumentError vals(p"bd" + 1)
end

@testset "add / sub / mul en pipe" begin
    @test nv(:bd |> n("0 3") |> add(:n, "<0 12>")) == [0, 3]
    @test nv(:bd |> n("0 3") |> add(:n, "<0 12>"), 1//1, 2//1) == [12, 15]
    @test nv(:bd |> n(5) |> sub(:n, 2)) == [3]
    @test [ev.value[:gain] for ev in (:bd |> gain(0.5) |> mul(:gain, 2))(0//1, 1//1)] == [1.0]
    @test nv(:bd |> add(:n, 7)) == [7]                       # clé absente : posée
end

# ---------------------------------------------------------------------------
@testset "concaténation — fastcat / slowcat / append / overlay / timeCat / ncat" begin
    @test vals(fastcat("bd", "hh sn")) == [:bd, :hh, :sn]
    @test starts(fastcat("bd", "hh sn")) == [0//1, 1//2, 3//4]
    @test percycle(slowcat("bd", "hh"), 3) == [[:bd], [:hh], [:bd]]
    @test percycle(append("bd", "hh"), 2) == [[:bd], [:hh]]
    @test vals(fastAppend("bd", "hh")) == [:bd, :hh]
    @test sort(vals(overlay("bd", "hh"))) == [:bd, :hh]
    @test starts(timeCat([(1, "bd*2"), (3, "hh")])) == [0//1, 1//8, 1//4]
    @test vals(timeCat([(1, "bd*2"), (3, "hh")])) == [:bd, :bd, :hh]
    @test percycle(ncat([(1, "bd"), (2, "hh")]), 4) == [[:bd], [:hh], [:hh], [:bd]]
    @test_throws ArgumentError timeCat([])
    # mélange Symbol / ControlMap : tout monte en ControlMap
    @test sv(fastcat("bd", :hh |> gain(0.5))) == [:bd, :hh]
end

@testset "randcat / wrandcat / wedge / spaceOut" begin
    rc = randcat("bd", "hh", "sn")
    @test all(length(v) == 1 && v[1] in (:bd, :hh, :sn) for v in percycle(rc, 8))
    @test percycle(rc, 8) == percycle(rc, 8)                       # déterministe
    @test length(unique(percycle(rc, 16))) > 1                    # varie
    wr = wrandcat([("bd", 100), ("hh", 0.0001)])
    @test all(v == [:bd] for v in percycle(wr, 10))
    @test starts(wedge(1//4, "bd*2", "hh*3")) == [0//1, 1//8, 1//4, 1//2, 3//4]
    @test_throws ArgumentError wedge(1, "bd", "hh")
    @test starts(spaceOut([1, 0.5, 2], "bd"), 0//1, 4//1) == [0//1, 1//1, 3//2, 7//2]
end

@testset "structure booléenne — inv / sew / stitch / euclidFull / binary / asciip / necklace / mono" begin
    @test vals(inv(p"1 0 1")) == [false, true, false]
    @test vals(sew("1 0", "bd*4", "hh*4")) == [:bd, :bd, :hh, :hh]
    @test vals(stitch("1 0 1 1", "bd", "hh")) == [:bd, :hh, :bd, :bd]
    @test vals(euclidFull(3, 8, "bd", "hh")) == [:bd, :hh, :hh, :bd, :hh, :hh, :bd, :hh]
    @test vals(binaryN(4, 5)) == [false, true, false, true]
    @test length(vals(binary(3))) == 8 && vals(binary(3))[7:8] == [true, true]
    @test length(vals(asciip("ab"))) == 16
    @test vals(necklace(8, [3, 2])) == [true, false, false, true, false, true, false, false]
    @test vals(mask(necklace(4, [2]))(p"a*4")) == [:a, :a]
    @test starts(mono(stack(p"bd*4", p"hh*2"))) == [0//1, 1//4, 1//2, 3//4]
    @test_throws ArgumentError binaryN(0, 1)
end

@testset "conditionnel — every(n, o) / when / whenT / within / ifp / always / never / fix" begin
    @test percycle(every(3, 1, rev, p"a b"), 4) == [[:a, :b], [:b, :a], [:a, :b], [:a, :b]]
    @test percycle(p"a b" |> every(3, 1, rev), 2) == [[:a, :b], [:b, :a]]
    @test percycle(when(c -> c % 2 == 1, rev, p"a b"), 3) == [[:a, :b], [:b, :a], [:a, :b]]
    @test vals(whenT(t -> t < 1//2, fast(2), p"a b")) == [:a, :b, :b]
    @test vals(within(0, 0.5, rev, p"a b c d")) == [:d, :c, :c, :d]
    @test vals(p"a b c d" |> within((0.5, 1), rev)) == [:a, :b, :b, :a]
    @test percycle(ifp(iseven, rev, fast(2), p"a b"), 2) == [[:b, :a], [:a, :b, :a, :b]]
    @test vals(always(rev, p"a b")) == [:b, :a]
    @test vals(never(rev, p"a b")) == [:a, :b]
    @test almostAlways(rev)(p"a b") isa Pattern && almostNever(rev)(p"a b") isa Pattern
    @test somecycles === someCycles && somecyclesBy === someCyclesBy
    # every(n, o, f) et every(n, f) coexistent
    @test percycle(every(2, rev, p"a b"), 2) == [[:b, :a], [:a, :b]]
    # f qui change le type (Symbol → ControlMap) : tout monte en ControlMap
    @test nv(when(c -> c == 0, x -> x |> n(1), p"a b")) == [1, 1]
end

@testset "fix / unfix / contrast" begin
    p = fix(x -> x |> n(9), :s => :bd, "bd hh bd")
    @test nv(p) == [9, nothing, 9]
    @test nv(unfix(x -> x |> n(9), :s => :bd, "bd hh bd")) == [nothing, 9, nothing]
    @test nv(contrast(x -> x |> n(1), x -> x |> n(2), Dict(:s => "hh"), "bd hh")) == [2, 1]
    @test nv("bd hh" |> fix(x -> x |> n(5), [:s => :hh])) == [nothing, 5]
    # correspondance numérique
    @test nv(fix(x -> x |> gain(0), :n => 2, :bd |> n("1 2"))) == [1, 2]
    @test [get(ev.value, :gain, 1) for ev in fix(x -> x |> gain(0), :n => 2, :bd |> n("1 2"))(0//1, 1//1)] == [1, 0]
end

@testset "aléatoire — irand / brand / chooseBy / wchoose / unDegradeBy / randslice" begin
    ir = vals(irand(8) |> segment(4))
    @test length(ir) == 4 && all(0 <= v < 8 for v in ir) && all(v isa Int for v in ir)
    @test all(v isa Bool for v in vals(brand() |> segment(4)))
    @test all(vals(brandBy(1.0) |> segment(4)))
    @test all(v in (:a, :b, :c) for v in vals(chooseBy(rand_pat() |> segment(4), [:a, :b, :c])))
    @test all(v == [:a] for v in percycle(wchoose([(:a, 1), (:b, 0)]), 6))
    @test all(v in (:a, :b) for v in vals(wchooseBy(rand_pat() |> segment(4), [(:a, 1), (:b, 1)])))
    @test cycleChoose === choose
    d = vals(degradeBy(0.5, p"hh*16")); u = vals(unDegradeBy(0.5, p"hh*16"))
    @test length(d) + length(u) == 16
    @test sort(vcat(starts(degradeBy(0.5, p"hh*16")), starts(unDegradeBy(0.5, p"hh*16")))) == starts(p"hh*16")
    rs = randslice(4, "bd*2")(0//1, 1//1)
    @test length(rs) == 2 && all(ev.value[:end] - ev.value[:begin] ≈ 0.25f0 for ev in rs)
end

@testset "select / selectF / pickF / squeeze / bite / chew" begin
    @test vals(select("0 0.6", ["bd*2", "hh*2"])) == [:bd, :hh]
    @test vals(select(0.9, ["bd", "hh"])) == [:hh]
    @test vals(selectF(0.6, [rev, fast(2)], "a b")) == [:a, :b, :a, :b]
    @test vals(pickF("0 1", [rev, fast(2)], "a b")) == [:b, :a, :b]
    @test vals(pickF("2", [rev, fast(2)], "a b")) == [:b, :a]              # modulo
    sq = squeeze("0 1*2", ["bd sn", "hh*3"])
    @test starts(sq) == [0//1, 1//4, 1//2, 7//12, 2//3, 3//4, 5//6, 11//12]
    @test vals(sq) == [:bd, :sn, :hh, :hh, :hh, :hh, :hh, :hh]
    b = bite(4, "0 2*2", "a b c d")
    @test vals(b) == [:a, :c, :c] && starts(b) == [0//1, 1//2, 3//4]
    @test vals(p"a b c d" |> bite(2, "1 0")) == [:c, :d, :a, :b]
    ch = chew(4, "0 [2 2]", "a b c d")(0//1, 1//1)
    @test [ev.value[:speed] for ev in ch] == [0.5, 1.0, 1.0]
    @test_throws ArgumentError bite(0, "0", "a")
end

@testset "tranches — striate / striateBy / slice / splice / loopAt / smash / fit" begin
    st = striate(2, "bd sn")(0//1, 1//1)
    @test [(ev.value[:s], ev.value[:begin]) for ev in st] == [(:bd, 0.0f0), (:sn, 0.0f0), (:bd, 0.5f0), (:sn, 0.5f0)]
    sb = striateBy(3, 0.5, :bd)(0//1, 1//1)
    @test [(ev.value[:begin], ev.value[:end]) for ev in sb] == [(0.0f0, 0.5f0), (0.25f0, 0.75f0), (0.5f0, 1.0f0)]
    sl = slice(4, "3 1", :amen)(0//1, 1//1)
    @test [(ev.value[:begin], ev.start) for ev in sl] == [(0.75f0, 0//1), (0.25f0, 1//2)]
    sp = splice(4, "3 1", :amen)(0//1, 1//1)
    @test all(ev.value[:speed] == 0.5 && ev.value[:unit] === :c for ev in sp)
    la = loopAt(2, :breaks)(0//1, 2//1)
    @test length(la) == 1 && la[1].value[:speed] == 0.5 && la[1].value[:unit] === :c
    @test length(smash(2, [1, 2], :bd)(0//1, 3//1)) == 5
    @test percycle(fit(1, [0, 3, 7], "0 1"), 3) == [[0, 3], [3, 7], [7, 0]]
    @test_throws ArgumentError slice(0, "0", :bd)
end

@testset "accumulation — echo / echoWith / stutter / plyWith / arpeggiate / spread* / chunkBack" begin
    @test starts(echo(3, 1//8, 0.5, "bd")) == [0//1, 1//8, 1//4]
    @test [get(ev.value, :gain, 1) for ev in echo(3, 1//8, 0.5, "bd")(0//1, 1//1)] == [1, 0.5, 0.25]
    @test starts(stutter(3, 1//8, "bd")) == [0//1, 1//8, 1//4]
    @test vals(stutter(3, 1//8, "bd")) == [:bd, :bd, :bd]
    @test nv(echoWith(3, 1//8, x -> x |> add(:n, 12), :bd |> n(0))) == [0, 12, 24]
    @test stutWith === echoWith
    pw = plyWith(3, gain(0.5), "bd")(0//1, 1//1)
    @test [get(ev.value, :gain, 1) for ev in pw] == [1, 0.5, 0.25] && [ev.start for ev in pw] == [0//1, 1//3, 2//3]
    @test starts(arpeggiate(stack(p"a", p"b"))) == [0//1, 1//2]
    @test vals(arpg(stack(p"b", p"a"))) == [:b, :a]                # ordre d'empilement, pas de tri
    @test percycle(spread(fast, [1, 2], "bd"), 2) == [[:bd], [:bd, :bd]]
    @test vals(fastspread(fast, [1, 2], "bd")) == [:bd, :bd, :bd]
    @test percycle(spreadf([rev, fast(2)], "a b"), 2) == [[:b, :a], [:a, :b, :a, :b]]
    @test all(v in ([:bd], [:bd, :bd]) for v in percycle(spreadChoose(fast, [1, 2], "bd"), 6))
    @test spreadr === spreadChoose
    @test percycle(chunkBack(2, rev, p"a b"), 2) == [[:a, :a], [:b, :b]]
    @test percycle(chunk(2, rev, p"a b"), 2) == [[:b, :b], [:a, :a]]
end

@testset "ghost / press / truncp / weave / ur" begin
    g = ghost("bd")(0//1, 1//1)
    @test [ev.start for ev in g] == [0//1, 3//16, 5//16, 1//2]        # 1,5a, 2,5a et 4a (Tidal)
    @test [get(ev.value, :gain, 1) for ev in g] ≈ [1, 0.7, 0.7, 0.49]
    @test starts(ghostWith(1//4, identity, p"bd")) == [0//1, 0//1, 3//8, 5//8]
    @test starts(press(p"a b")) == [1//4, 3//4]
    @test starts(pressBy(1//4, p"a b")) == [1//8, 5//8]
    @test starts(p"a b" |> press) == [1//4, 3//4]
    @test starts(truncp(3//4, p"a b c d")) == [0//1, 1//4, 1//2]
    @test starts(p"a*4" |> truncp(1//2), 1//1, 2//1) == [1//1, 5//4]
    w = weave(2, pan, saw(), ["bd", "hh"])(0//1, 1//1)
    @test [(ev.value[:s], ev.value[:pan]) for ev in w] == [(:bd, 0.25), (:hh, 0.75)]
    ww = weaveWith(2, "a b", [fast(2), rev])
    @test length(ww(0//1, 1//1)) == 6
    u = ur(2, "a b:x", Dict("a" => "bd*2", "b" => "hh*2"), Dict("x" => fast(2)))
    @test sv(u, 0//1, 2//1) == [:bd, :bd, :hh, :hh, :hh, :hh]
    @test starts(u, 0//1, 2//1) == [0//1, 1//2, 1//1, 5//4, 3//2, 7//4]
end

@testset "valeurs — quantise / smooth / rangex / toScale / scan / discretise" begin
    @test vals(quantise(p"0.4 1.6")) == [0, 2]
    @test vals(smooth(p"0 1"), 1//4, 26//100) ≈ [0.51]
    @test vals(smooth(p"0 1"), 0//1, 1//100) ≈ [0.01]
    rx = vals(rangex(100, 10000, sine() |> segment(2)))
    @test rx[1] ≈ 10000 && rx[2] ≈ 100
    @test vals(toScale([0, 2, 4, 5, 7, 9, 11], "0 1 2 7 -1")) == [0, 2, 4, 12, -1]
    @test nv(:pad |> n(toScale([0, 2, 4], "0 3"))) == [0, 12]
    @test percycle(scan(3), 3) == [[0], [0, 1], [0, 1, 2]]
    @test discretise === segment
    @test vals(segment(2, p"a b c d")) == [:a, :c]                   # segment générique
end
