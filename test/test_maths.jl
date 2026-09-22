# Mathématiques musicales : courbes, lois, suites, conversions, et
# l'interopérabilité Julia ⟷ mini-notation.
using Test
using Ressac

vals(p, n = 4) = [ev.value for ev in sort((p |> segment(n))(0//1, 1//1); by = e -> e.start)]

@testset "lois de probabilité — bornes, forme, déterminisme" begin
    u = vals(uniform(0, 10), 8)
    @test length(u) == 8 && all(0 <= x < 10 for x in u)
    @test vals(uniform(0, 10), 8) == u                      # rejouable à l'identique
    @test all(x -> x isa Float64, u)
    # une normale reste groupée : l'écart-type empirique suit σ
    ns = [ev.value for ev in (normal(0, 1) |> segment(64))(0//1, 1//1)]
    @test abs(sum(ns) / length(ns)) < 0.4
    @test count(x -> abs(x) < 2, ns) / length(ns) > 0.85
    @test all(>=(0), vals(expo(2), 16))
    @test all(x -> x isa Bool, vals(bernoulli(0.5), 8))
    @test all(x -> x isa Int && x >= 0, vals(poisson(2.0), 8))
    @test count(vals(bernoulli(1.0), 16)) == 16
    @test count(vals(bernoulli(0.0), 16)) == 0
    # la marche dérive lentement : deux cycles voisins restent proches
    w = [walk(0.1)(Rational{Int64}(c), Rational{Int64}(c + 1))[1].value for c in 0:20]
    @test all(0 <= x <= 1 for x in w)
    @test maximum(abs.(diff(w))) <= 0.11
    @test w == [walk(0.1)(Rational{Int64}(c), Rational{Int64}(c + 1))[1].value for c in 0:20]
    # markov : un état par cycle, pris dans la liste, reproductible
    mk = markov([[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]], [:a, :b, :c])
    @test [mk(Rational{Int64}(c), Rational{Int64}(c + 1))[1].value for c in 0:4] == [:a, :a, :a, :a, :a]
    mk2 = markov([[0, 1.0], [1.0, 0]], [:x, :y])
    @test [mk2(Rational{Int64}(c), Rational{Int64}(c + 1))[1].value for c in 0:3] == [:x, :y, :x, :y]
    @test_throws ArgumentError markov([[1.0]], [:a, :b])
end

@testset "courbes — rampes linéaire, géométrique, quelconque" begin
    r = vals(ramp(0, 1), 4)
    @test issorted(r) && r[1] ≈ 0.125 && r[end] ≈ 0.875
    e = vals(expramp(100, 800), 4)
    @test issorted(e) && e[1] > 100 && e[end] < 800
    # géométrique : le rapport entre pas successifs est constant
    ratios = [e[i + 1] / e[i] for i in 1:(length(e) - 1)]
    @test all(x -> isapprox(x, ratios[1]; rtol = 1e-6), ratios)
    @test_throws ArgumentError expramp(0, 100)
    @test vals(curve(t -> t^2), 4) ≈ [0.125^2, 0.375^2, 0.625^2, 0.875^2]
    @test [ev.value[:cutoff] for ev in (:pad |> lpf(ramp(100, 900) |> segment(2)))(0//1, 1//1)] ≈ [300.0, 700.0]
end

@testset "suites de nombres" begin
    @test fib(8) == [1, 1, 2, 3, 5, 8, 13, 21]
    @test fib(3; from = 5) == [5, 8, 13]
    @test primes_n(6) == [2, 3, 5, 7, 11, 13]
    @test harmonics(4; fundamental = 110) == [110.0, 220.0, 330.0, 440.0]
    @test length(logistic_map(3.9, 10)) == 10
    @test all(0 <= x <= 1 for x in logistic_map(3.9, 50))
    @test logistic_map(2.5, 30)[end] ≈ 0.6 atol = 0.01        # converge
    @test Int.(euclid_steps(3, 8)) == [1, 0, 0, 1, 0, 0, 1, 0]
    @test count(euclid_steps(5, 16)) == 5
    @test_throws ArgumentError fib(0)
    @test_throws ArgumentError primes_n(0)
    # une suite se joue directement
    @test [ev.value[:n] for ev in (:pad |> n(fib(4)))(0//1, 1//1)] == [1, 1, 2, 3]
end

@testset "hauteurs et fréquences" begin
    @test ratio_to_cents(2) ≈ 1200
    @test ratio_to_cents(3//2) ≈ 701.955 atol = 0.01
    @test cents_to_ratio(1200) ≈ 2
    @test cents_to_ratio(ratio_to_cents(5//4)) ≈ 1.25
    @test midi_to_hz(69) ≈ 440
    @test midi_to_hz(60) ≈ 261.626 atol = 0.01
    @test hz_to_midi(440) ≈ 69
    @test hz_to_midi(midi_to_hz(53.7)) ≈ 53.7
    @test semitones(2) ≈ 12
    @test semitones(3//2) ≈ 7.02 atol = 0.01
end

@testset "interop — patvals, tomini, pat, arguments patternés" begin
    @test patvals(p"0 3 7") == [0, 3, 7]
    @test patvals("bd sn") == [:bd, :sn]
    @test patvals(p"0 1", 1, 3) == [0, 1, 0, 1]
    @test sum(patvals(p"1 2 3")) == 6
    @test tomini([0, 3, 7]) == "0 3 7"
    @test tomini([[0, 3], 7, nothing]) == "[0 3] 7 ~"
    @test tomini([:bd, :sn]) == "bd sn"
    @test patvals(parse_minino(tomini([[0, 3], 7]))) == [0, 3, 7]
    @test pat(0:3) isa Pattern && patvals(pat(0:3)) == [0, 1, 2, 3]
    @test pat("bd") isa Pattern && pat(:bd) isa Pattern && pat(p"bd") isa Pattern
    # les arguments numériques acceptent un pattern
    @test length((p"bd" |> ply("<2 3>"))(0//1, 1//1)) == 2
    @test length((p"bd" |> ply("<2 3>"))(1//1, 2//1)) == 3
    @test [ev.value for ev in (p"a b c d" |> iter("<1 2>"))(1//1, 2//1)] == [:c, :d, :a, :b]
    @test length((p"hh*8" |> degradeBy("<0 1>"))(0//1, 1//1)) == 8
    @test length((p"hh*8" |> degradeBy("<0 1>"))(1//1, 2//1)) == 0
    @test [ev.value for ev in (p"a b" |> every("<1 4>", rev))(0//1, 1//1)] == [:b, :a]
    @test [ev.value for ev in (p"a b" |> every("<1 4>", rev))(1//1, 2//1)] == [:a, :b]
    @test length((sine() |> segment("<2 4>"))(1//1, 2//1)) == 4
    @test length((p"bd" |> ply(pat(2)))(0//1, 1//1)) == 2
end
