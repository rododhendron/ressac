using Test
using Ressac

@testset "nrt analysis — offline acoustic descriptors" begin
    # Tests purs (sans SC) : construction du script + lecture wav.
    @testset "script sclang : 1 def + 1 s_new par candidat, recordNRT" begin
        g = Ressac.Genome()
        s = Ressac.add_node!(g, :SinOsc, :ar,
                             Ressac.Arg[Ressac.ControlRef(:freq), Ressac.ConstArg(0.0)])
        g.output_id = s
        scd = Ressac._build_nrt_script([g, g], "/tmp/o.wav", "/tmp/o.osc")
        @test occursin("Score(", scd)
        @test occursin("recordNRT", scd)
        @test occursin("'/d_recv'", scd)
        @test occursin("'/s_new', \"nrt1\"", scd)
        @test occursin("'/s_new', \"nrt2\"", scd)
        @test occursin("numOutputBusChannels_($(Ressac.N_ANALYSIS_CHANNELS))", scd)
    end

    @testset "descripteurs depuis une fenêtre wav synthétique" begin
        sr = 44100
        nf = sr                               # 1 s
        mat = zeros(Float64, Ressac.N_ANALYSIS_CHANNELS, nf)
        mat[1, :] .= 0.7                       # centroïde
        mat[2, :] .= 0.9                       # subratio (basse)
        mat[3, :] .= 0.1                       # platitude (tonal)
        mat[4, :] .= 0.5                       # amp (constant → tenu, attaque immédiate)
        mat[5, :] .= 0.8                       # pitchconf
        d = Ressac._descriptors_from_window(mat, sr, 0.0, 0.3)
        @test length(d) == Ressac.N_DESCRIPTORS
        @test d[1] ≈ 0.7 atol = 0.05           # centroïde
        @test d[2] ≈ 0.9 atol = 0.05           # subratio
        @test d[3] ≈ 0.1 atol = 0.05           # platitude
        @test d[4] ≈ 1.0 atol = 0.05           # attaque (pic immédiat)
        @test d[5] ≈ 1.0 atol = 0.05           # tenue (amp constant)
        @test d[6] ≈ 0.8 atol = 0.05           # pitchconf
    end

    # Intégration NRT réelle : LENTE (sclang compile sa classlib ~15 s par
    # appel) → JAMAIS dans la suite par défaut. Opt-in explicite via
    # RESSAC_NRT_TESTS=1 (et sclang dispo). `just test-nrt` la lance.
    if get(ENV, "RESSAC_NRT_TESTS", "") == "1" && Ressac._sclang_available()
        @testset "rendu NRT headless : sinus grave vs bruit blanc" begin
            gs = Ressac.Genome()
            s = Ressac.add_node!(gs, :SinOsc, :ar,
                                 Ressac.Arg[Ressac.ControlRef(:freq), Ressac.ConstArg(0.0)])
            gs.output_id = s; gs.controls[:freq] = 80.0
            gn = Ressac.Genome()
            n = Ressac.add_node!(gn, :WhiteNoise, :ar, Ressac.Arg[])
            gn.output_id = n
            d = Ressac.analyze_genomes(Ressac.Genome[gs, gn])
            @test length(d) == 2
            ci = findfirst(==(:centroid), Ressac.DESCRIPTORS)
            fi = findfirst(==(:flatness), Ressac.DESCRIPTORS)
            si = findfirst(==(:subratio), Ressac.DESCRIPTORS)
            # sinus grave : centroïde bas, graves élevés ; bruit : platitude haute
            @test d[1][ci] < d[2][ci]          # sine moins brillant que le bruit
            @test d[1][si] > d[2][si]          # sine plus de graves
            @test d[2][fi] > d[1][fi]          # bruit plus plat (spectralement)
        end
    else
        @info "nrt: test d'intégration sauté (RESSAC_NRT_TESTS=1 pour le lancer)"
    end
end
