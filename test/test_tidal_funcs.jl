# Tour des fonctions Tidal ajoutées : rot, hurry, shuffle, scramble, linger,
# swing, whenmod, someCycles, fastGap, compress, zoom, euclid*, superimpose,
# layer, inside/outside, rolled, brak, stut, mask("…").
using Test
using Ressac

vals(p, s = 0//1, e = 1//1) = [ev.value for ev in sort(p(s, e); by = ev -> ev.start)]
starts(p, s = 0//1, e = 1//1) = [ev.start for ev in sort(p(s, e); by = ev -> ev.start)]

@testset "rot — les valeurs tournent, la structure reste" begin
    p = p"bd hh sn"
    @test vals(p |> rot(1)) == [:hh, :sn, :bd]
    @test vals(p |> rot(-1)) == [:sn, :bd, :hh]
    @test starts(p |> rot(1)) == starts(p)
    @test vals(p"bd ~ sn hh" |> rot(1)) == [:sn, :hh, :bd]      # le silence ne compte pas
end

@testset "hurry — fast + speed" begin
    evs = (p"bd" |> hurry(2))(0//1, 1//1)
    @test length(evs) == 2 && all(ev.value[:speed] == 2 for ev in evs)
end

@testset "shuffle / scramble — morceaux réordonnés, déterministes par cycle" begin
    p = p"a b c d"
    sh = p |> shuffle(4)
    @test sort(vals(sh)) == [:a, :b, :c, :d]                  # chaque morceau une fois
    @test vals(sh) == vals(sh)                                # déterministe
    @test starts(sh) == [0//1, 1//4, 1//2, 3//4]
    sc = p |> scramble(4)
    @test length(vals(sc)) == 4 && all(v in (:a, :b, :c, :d) for v in vals(sc))
    @test starts(sc) == [0//1, 1//4, 1//2, 3//4]
end

@testset "linger — boucle le début du cycle" begin
    p = p"a b c d" |> linger(1//4)
    @test vals(p) == [:a, :a, :a, :a]
    @test starts(p) == [0//1, 1//4, 1//2, 3//4]
    @test vals(p"a b c d" |> linger(1//2)) == [:a, :b, :a, :b]
end

@testset "swingBy — la seconde moitié de chaque créneau est retardée" begin
    p = p"hh*8" |> swingBy(1//3, 4)
    st = starts(p)
    @test st[1] == 0//1
    @test st[2] == 1//8 + 1//12                               # 2e croche du 1er créneau
    @test st[3] == 1//4
    @test length(st) == 8
    @test starts(p"hh*8" |> swing(4)) == st
end

@testset "whenmod — f sur les cycles c mod a ≥ b" begin
    p = p"a b" |> whenmod(4, 2, rev)
    @test vals(p, 0//1, 1//1) == [:a, :b]
    @test vals(p, 1//1, 2//1) == [:a, :b]
    @test vals(p, 2//1, 3//1) == [:b, :a]
    @test vals(p, 3//1, 4//1) == [:b, :a]
    @test vals(p, 4//1, 5//1) == [:a, :b]
end

@testset "someCycles — alias par cycle de sometimesBy" begin
    p = p"a b" |> someCyclesBy(1.0, rev)
    @test vals(p) == [:b, :a]
    @test vals(p"a b" |> someCyclesBy(0.0, rev)) == [:a, :b]
    @test length(vals(p"a b" |> someCycles(rev))) == 2
end

@testset "fastGap / compress / zoom" begin
    fg = p"a b" |> fastGap(2)
    @test starts(fg) == [0//1, 1//4] && vals(fg) == [:a, :b]
    c = p"a b" |> compress(1//4, 3//4)
    @test starts(c) == [1//4, 1//2]
    @test (c(0//1, 1//1))[2].stop == 3//4
    z = p"a b c d" |> zoom(0, 1//2)
    @test vals(z) == [:a, :b] && starts(z) == [0//1, 1//2]
    @test_throws ArgumentError compress(1//2, 1//4, p"a")
end

@testset "euclid / euclidInv / euclidOff — structure euclidienne, valeurs de p" begin
    e = p"bd" |> euclid(3, 8)
    @test vals(e) == [:bd, :bd, :bd]
    @test starts(e) == [0//1, 3//8, 6//8]
    @test length(vals(p"bd" |> euclidInv(3, 8))) == 5
    eo = p"bd" |> euclidOff(3, 8, 2)
    @test starts(eo) == starts(p"bd(3,8,2)")
    # les valeurs suivent p : « bd sn » sur 2 pas → coups pris à leur instant
    e2 = p"bd sn" |> euclid(2, 4)
    @test vals(e2) == [:bd, :sn]
end

@testset "superimpose / layer / inside / outside" begin
    s = p"a b" |> superimpose(fast(2))
    @test length(vals(s)) == 6
    l = p"a" |> layer([fast(2), rev])
    @test length(vals(l)) == 3
    i = p"a b c d" |> inside(2, rev)
    @test vals(i) == [:b, :a, :d, :c]
    o = p"a b c d" |> outside(2, rev)
    @test vals(o, 0//1, 2//1) == [:d, :c, :b, :a, :d, :c, :b, :a] || length(vals(o, 0//1, 2//1)) == 8
end

@testset "rolled / rolledBy — les notes d'un accord partent en cascade" begin
    r = (p"c'maj" |> rolledBy(1//2))(0//1, 1//1)
    st = sort([ev.start for ev in r])
    @test st == [0//1, 1//6, 1//3]
    @test all(ev.stop == 1//1 for ev in r)
    @test sort([ev.start for ev in (p"c'maj" |> rolled)(0//1, 1//1)]) == [0//1, 1//12, 1//6]
end

@testset "brak — un cycle sur deux, tassé et décalé d'un quart" begin
    b = p"a b" |> brak
    @test starts(b, 0//1, 1//1) == [0//1, 1//2]
    @test starts(b, 1//1, 2//1) == [1//1 + 1//4, 1//1 + 1//2]
end

@testset "stut — écho avec gain décroissant" begin
    evs = (p"bd" |> stut(3, 0.5, 1//8))(0//1, 1//1)
    @test length(evs) == 3
    st = sort(evs; by = ev -> ev.start)
    @test [ev.start for ev in st] == [0//1, 1//8, 1//4]
    @test [ev.value[:gain] for ev in st[2:3]] == [0.5, 0.25]
end

@testset "mask — accepte une chaîne « 1 0 1 1 » ou « t f »" begin
    @test vals(p"a b c d" |> mask("1 0 1 1")) == [:a, :c, :d]
    @test vals(p"a b c d" |> mask("t f t f")) == [:a, :c]
end
