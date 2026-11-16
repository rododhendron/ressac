include(joinpath(@__DIR__, "helpers.jl"))
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

    # Le lanceur lui-même, sur un faux sclang (un script shell) : aucun vrai
    # sclang ici, donc dans la suite par défaut.
    @testset "_run_sclang — délai borné, processus tué" begin
        dir = mktempdir()
        fake(body) = (p = joinpath(dir, "fake-" * string(hash(body); base = 16));
                      write(p, "#!/bin/sh\n" * body * "\n"); chmod(p, 0o755); p)
        old = Ressac._SCLANG_BIN[]
        try
            # Un sclang resté dans sa boucle d'interprétation (erreur de syntaxe).
            Ressac._SCLANG_BIN[] = fake("exec sleep 30")
            t0 = time()
            err = try Ressac._run_sclang("x.scd"; timeout = 0.3); nothing catch e; e end
            @test err isa ErrorException && occursin("n'a pas rendu la main", err.msg)
            @test time() - t0 < 5.0
            # Sortie normale et sortie en erreur (le `1.exit` du try SC).
            Ressac._SCLANG_BIN[] = fake("exit 0")
            @test Ressac._run_sclang("x.scd"; timeout = 5) == 0
            Ressac._SCLANG_BIN[] = fake("exit 1")
            @test Ressac._run_sclang("x.scd"; timeout = 5) == 1
        finally
            Ressac._SCLANG_BIN[] = old
        end
    end

    @testset "les scripts NRT sortent toujours de sclang" begin
        g = Ressac.Genome()
        n = Ressac.add_node!(g, :WhiteNoise, :ar, Ressac.Arg[]); g.output_id = n
        for script in (Ressac._build_nrt_script(Ressac.Genome[g], "o.wav", "o.osc"),
                       Ressac._build_audio_script(g, "o.wav", "o.osc", 0.5))
            @test startswith(script, "try {")
            @test occursin("action: { 0.exit }", script)
            @test occursin("{ |err| err.reportError; 1.exit };", script)
        end
    end

    # Intégration NRT réelle : LENTE (sclang compile sa classlib ~15 s par
    # appel) → JAMAIS dans la suite par défaut. Opt-in explicite via
    # RESSAC_NRT_TESTS=1 (et sclang dispo). `just test-nrt` la lance.
    if get(ENV, "RESSAC_NRT_TESTS", "") == "1"
        # Opt-in demandé : l'absence de sclang est un échec, pas un saut.
        @test Ressac._sclang_available()
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

    if get(ENV, "RESSAC_NRT_TESTS", "") == "1"
        # Opt-in demandé : l'absence de sclang est un échec, pas un saut.
        @test Ressac._sclang_available()
        @testset "render_genome_audio capture l'onde complète (mono)" begin
            g = Ressac.Genome()
            s = Ressac.add_node!(g, :SinOsc, :ar,
                                 Ressac.Arg[Ressac.ControlRef(:freq), Ressac.ConstArg(0.0)])
            g.output_id = s; g.controls[:freq] = 220.0; g.controls[:sustain] = 0.4
            samples, sr = Ressac.render_genome_audio(g)
            @test sr == 44100
            @test length(samples) > 10000               # ~0.5s de son
            @test maximum(abs, samples) > 0.05           # non silencieux
            @test maximum(abs, samples) <= 1.0           # borné (Limiter)
        end
    end
end
