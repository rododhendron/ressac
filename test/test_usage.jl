include(joinpath(@__DIR__, "helpers.jl"))
# Ce qui a été joué : comptage, voisines, « pas encore essayé » — étape E4.3.

function _us_reset!()
    empty!(Ressac._PLAYED[]); Ressac._PLAYED_LOADED[] = true
    rm(Ressac._played_path(); force = true)
end

@testset "usage — ce qui a été joué" begin

    @testset "les noms documentés du code, pas ceux des chaînes ni des commentaires" begin
        names = Ressac._played_names("@d1 p\"bd fast\" |> gain(0.5) |> lpf(\"<400 800>\")  # every\nx = 3")
        @test "gain" in names && "lpf" in names
        @test !("every" in names) && !("fast" in names) && !("x" in names) && !("bd" in names)
        @test Ressac._played_names("@d1 p\"bd\" |> gain(1) |> gain(2)") == ["p", "gain"]   # une fois par évaluation
    end

    @testset "une évaluation réussie compte ; une ratée non ; ça tient d'un lancement à l'autre" begin
        _us_reset!()
        _with_live_app() do app, _
            _set_buffer!(app, "@d1 p\"bd\" |> gain(0.5) |> lpf(800)")
            _key!(app, 'E')
            @test Ressac._played_count("gain") == 1 && Ressac._played_count("lpf") == 1
            _key!(app, 'e')
            @test Ressac._played_count("gain") == 2
            _set_buffer!(app, "@d1 p\"bd\" |> hpf(200) |> nexiste_pas(1)")
            _key!(app, 'e')
            @test Ressac._played_count("hpf") == 0                          # la ligne n'a pas joué
        end
        @test isfile(Ressac._played_path())
        empty!(Ressac._PLAYED[]); Ressac._PLAYED_LOADED[] = false           # un nouveau lancement
        @test Ressac._played_count("gain") == 2
    end

    @testset "voisines d'une fiche : les fonctions de sa ligne « See also »" begin
        e = Ressac.lookup_doc("lpf")
        near = Ressac._doc_neighbours(e)
        @test "hpf" in near && !("lpf" in near)
        @test all(Ressac._is_documented_function, near)                      # pas les termes de glossaire
        @test !("low-pass filter" in near)
    end

    @testset "la fiche montre les voisines, et la première jamais jouée" begin
        _us_reset!()
        lines(name) = [join(sp.content for sp in l) for l in Ressac._doc_pane_lines(name, 60)]
        txt = join(lines("lpf"), "\n")
        near = Ressac._doc_neighbours(Ressac.lookup_doc("lpf"))
        @test occursin("voisines", txt) && occursin("○ pas encore essayé : $(near[1])", txt)
        Ressac._note_played!("x |> $(near[1])(1)")
        txt = join(lines("lpf"), "\n")
        @test !occursin("pas encore essayé : $(near[1])", txt)               # essayée : on passe à la suivante, ou rien
        foreach(n -> Ressac._note_played!("x |> $n(1)"), near)
        @test !occursin("pas encore essayé", join(lines("lpf"), "\n"))
    end

    @testset "la fiche à l'écran se met à jour quand on joue" begin
        _us_reset!()
        p = Ressac.DocPane("lpf", 0, false)
        Ressac._doc_sync!(p, 50)
        k1 = p.rendered
        Ressac._note_played!("x |> hpf(200)")
        Ressac._doc_sync!(p, 50)
        @test p.rendered != k1
    end

    @testset "la complétion propose d'abord ce qu'on joue" begin
        _us_reset!()
        @test Ressac._played_count("hurry") == 0
        for _ in 1:3; Ressac._note_played!("x |> hurry(2)"); end
        @test Ressac._played_count("hurry") == 3
    end
end
_us_reset!()
