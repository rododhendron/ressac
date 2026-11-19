include(joinpath(@__DIR__, "helpers.jl"))
# Fonctions d'état : nTake, sTake, nCount — la valeur d'un coup dépend de son rang.

_tk_vals(p, key, c) = [ev.value[key] for ev in sort(p(c // 1, (c + 1) // 1); by = e -> e.start)]

@testset "nTake / sTake / nCount" begin
    p = p"bd*3 bd" |> nTake([0, 3, 7])
    # La liste avance d'un cran par coup, pas par cycle.
    @test _tk_vals(p, :n, 0) == [0, 3, 7, 0]
    @test _tk_vals(p, :n, 1) == [3, 7, 0, 3]
    @test _tk_vals(p, :n, 2) == [7, 0, 3, 7]
    # Pur : demander deux fois, dans le désordre, ou par morceaux, ne change rien.
    @test _tk_vals(p, :n, 1) == [3, 7, 0, 3]
    q = p"bd*3 bd" |> nTake([0, 3, 7])
    @test _tk_vals(q, :n, 5) == _tk_vals(p, :n, 5)
    half = sort(q(1 // 1, 3 // 2); by = e -> e.start)
    @test [ev.value[:n] for ev in half] == _tk_vals(p, :n, 1)[1:length(half)]
    # Le son d'origine est gardé.
    @test all(ev -> ev.value[:s] === :bd, p(0 // 1, 1 // 1))
    # Un rythme qui change d'un cycle à l'autre : le compte suit les vrais coups.
    alt = p"<bd bd*2>" |> nCount()
    @test _tk_vals(alt, :n, 0) == [0]
    @test _tk_vals(alt, :n, 1) == [1, 2]
    @test _tk_vals(alt, :n, 2) == [3]
    @test _tk_vals(p"hh*4" |> nCount(3), :n, 0) == [0, 1, 2, 0]
    @test _tk_vals(p"hh*4" |> nCount(3), :n, 1) == [1, 2, 0, 1]
    # sTake : les sons, à leur tour.
    s = p"x*4" |> sTake([:bd, :hh, :cp])
    @test _tk_vals(s, :s, 0) == [:bd, :hh, :cp, :bd]
    @test _tk_vals(s, :s, 1) == [:hh, :cp, :bd, :hh]
    # Une liste vide ne casse rien.
    @test length((p"bd*2" |> nTake(Int[]))(0 // 1, 1 // 1)) == 2
end
