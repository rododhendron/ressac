# Dégagement du mix : duck, avoid, band, slot_band, fan, declash, clashes.
using Test
using Ressac

gains(p, a = 0, b = 1) =
    [get(ev.value, :gain, 1.0) for ev in sort(p(Rational{Int64}(a), Rational{Int64}(b)); by = e -> e.start)]
starts(p, a = 0, b = 1) =
    [ev.start for ev in sort(p(Rational{Int64}(a), Rational{Int64}(b)); by = e -> e.start)]

@testset "duck — le gain plonge sur l'attaque du déclencheur et remonte" begin
    g = gains(pat("hh*8") |> duck("bd*2"; depth = 0.9, release = 1//4))
    @test length(g) == 8
    @test g[1] ≈ 0.1 atol = 0.01          # pile sur le kick
    @test g[2] ≈ 0.55 atol = 0.01         # à mi-remontée
    @test g[3] ≈ 1.0 && g[4] ≈ 1.0        # release terminée
    @test g[5] ≈ 0.1 atol = 0.01          # deuxième kick
    @test issorted(g[1:4])
    # sans attaque du déclencheur, rien ne bouge
    @test all(≈(1.0), gains(pat("hh*4") |> duck(silence(Symbol))))
    # le gain déjà posé est multiplié, pas écrasé
    g2 = gains(pat("hh*2") |> gain(0.5) |> duck("bd*2"; depth = 1.0, release = 1//2))
    @test g2[1] ≈ 0.0 atol = 1e-9
    # depth = 0 ne change rien
    @test all(≈(1.0), gains(pat("hh*4") |> duck("bd*4"; depth = 0)))
    # un coup du cycle précédent compte encore
    @test gains(pat("hh*4") |> duck(pat("bd"); release = 4), 1, 2)[1] < 1.0
    @test_throws ArgumentError duck("bd"; release = 0)
end

@testset "avoid — écarte ou supprime ce qui tombe trop près" begin
    # hh*8 contre bd*2 : les coups à 0 et 1/2 tombent pile dessus
    @test starts(pat("hh*8") |> avoid("bd*2")) == [1//8, 1//4, 3//8, 5//8, 3//4, 7//8]
    # en mode nudge ils sont décalés, pas perdus
    n = starts(pat("hh*4") |> avoid("bd*2"; mode = :nudge, window = 1//16))
    @test length(n) == 4 && 1//16 in n
    # une fenêtre nulle ne retire rien
    @test length(starts(pat("hh*8") |> avoid("bd*2"; window = 1//10000))) == 6
    @test starts(pat("hh*4") |> avoid(silence(Symbol))) == [0//1, 1//4, 1//2, 3//4]
    @test_throws ArgumentError avoid("bd"; mode = :autre)
    @test_throws ArgumentError avoid("bd"; window = 0)
end

@testset "band / slot_band / fan — fenêtres et places" begin
    ev = (:pad |> band(250, 2000))(0//1, 1//1)[1].value
    @test ev[:hcutoff] == 250 && ev[:cutoff] == 2000
    # les fenêtres se touchent sans se recouvrir et couvrent tout l'intervalle
    edges = Float64[]
    for i in 1:3
        v = (:pad |> slot_band(i, 3; lo = 100, hi = 8000))(0//1, 1//1)[1].value
        push!(edges, v[:hcutoff]); push!(edges, v[:cutoff])
    end
    @test edges[1] ≈ 100 && edges[end] ≈ 8000
    @test edges[2] ≈ edges[3] && edges[4] ≈ edges[5]
    @test issorted(edges)
    @test_throws ArgumentError slot_band(4, 3)
    # stéréo : première à gauche, dernière à droite, centre au milieu
    pans = [(:pad |> fan(i, 3))(0//1, 1//1)[1].value[:pan] for i in 1:3]
    @test pans[1] ≈ 0.1 && pans[2] ≈ 0.5 && pans[3] ≈ 0.9
    @test (:pad |> fan(1, 1))(0//1, 1//1)[1].value[:pan] ≈ 0.5
    @test (:pad |> fan(1, 3; width = 0))(0//1, 1//1)[1].value[:pan] ≈ 0.5
    @test_throws ArgumentError fan(0, 3)
end

@testset "declash — les trois traitements d'un coup" begin
    voix = declash([pat("bd*4"), pat("hh*8"), :pad]; duck_first = 1)
    @test length(voix) == 3
    v1 = voix[1](0//1, 1//1)[1].value
    v3 = voix[3](0//1, 1//1)[1].value
    @test v1[:hcutoff] < v3[:hcutoff]            # chacun sa fenêtre
    @test v1[:pan] < v3[:pan]                    # chacun sa place
    @test all(≈(1.0), gains(voix[1]))            # le déclencheur ne se duck pas
    @test minimum(gains(voix[2])) < 0.5          # les autres si
    # sans ducking demandé, aucun gain n'est touché
    plain = declash([pat("bd*4"), pat("hh*8")])
    @test all(≈(1.0), gains(plain[2]))
    # on peut ne demander qu'une chose
    only_pan = declash([pat("bd"), pat("sn")]; bands = false)
    @test !haskey(only_pan[1](0//1, 1//1)[1].value, :cutoff)
    @test haskey(only_pan[1](0//1, 1//1)[1].value, :pan)
    @test isempty(declash([]))
    @test_throws ArgumentError declash([pat("bd")]; duck_first = 2)
end

@testset "clashes — dit ce qui se cogne et quoi essayer" begin
    c = clashes(Dict(:d1 => pat("bd*4"), :d2 => pat("bd*4"), :d3 => pat("hh*3")))
    @test !isempty(c)
    a, b, share, note = c[1]
    @test Set([a, b]) == Set([:d1, :d2])          # la paire identique d'abord
    @test share ≈ 1.0
    @test occursin("duck", note) || occursin("slot_band", note)
    # deux voix décalées ne se cognent pas
    @test isempty(clashes(Dict(:d1 => pat("bd ~"), :d2 => pat("~ sn"))))
    # des bandes séparées changent le conseil
    c2 = clashes(Dict(:d1 => (pat("bd*4") |> band(40, 200)),
                      :d2 => (pat("sn*4") |> band(2000, 9000))))
    @test !isempty(c2) && occursin("bandes séparées", c2[1][4])
    # deux voix sans filtre : on ne prétend pas savoir qu'elles se masquent
    c3 = clashes(Dict(:d1 => pat("bd*4"), :d2 => pat("sn*4")))
    @test occursin("duck ou avoid", c3[1][4]) && !occursin("mêmes fréquences", c3[1][4])
    # une seule filtrée : le conseil est de donner une fenêtre à l'autre
    c4 = clashes(Dict(:d1 => (pat("bd*4") |> band(40, 200)), :d2 => pat("sn*4")))
    @test occursin("n'a pas de fenêtre", c4[1][4])
    # la proportion retenue est celle du point de vue le plus gêné
    c5 = clashes(Dict(:d1 => pat("bd*2"), :d2 => pat("hh*8")))
    @test c5[1][3] ≈ 1.0
    @test isempty(clashes(Dict{Symbol,Pattern}()))
end
