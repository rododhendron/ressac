include(joinpath(@__DIR__, "helpers.jl"))
import Random
# Plugins — roadmap phase 5 : version de Tachikoma, isolation des fichiers
# mal formés, ordre des sections, détection des fichiers de synth.

@testset "plugins — règles" begin

    @testset "P1 — Tachikoma épinglé, correctifs conditionnés à sa version" begin
        project = read(joinpath(@__DIR__, "..", "Project.toml"), String)
        @test occursin("Tachikoma = \"=$(Ressac._TK_PATCHED_VERSION)\"", project)
        @test pkgversion(Tachikoma) == Ressac._TK_PATCHED_VERSION
        @test Ressac._tk_patches_apply()
        # Chaque fonction que Ressac remplace existe bien dans cette version.
        for fn in (:_ensure_tokens!, :read_event, :read_ss3, :tokenize_line)
            @test isdefined(Tachikoma, fn)
        end
    end

    @testset "P3 — un fichier mal formé ne coûte que lui-même" begin
        with_clean_registries() do
            mktempdir() do dir
                p = joinpath(dir, "malforme")
                mkpath(joinpath(p, "snippets")); mkpath(joinpath(p, "docs"))
                write(joinpath(p, "plugin.toml"), "name = \"malforme\"\nversion = \"0.1.0\"\ndescription = \"t\"\n[snippets]\ndir = \"snippets\"\n[docs]\ndir = \"docs\"\n")
                for (name, desc) in (("a_bad", "3"), ("b_good", "\"ok\""), ("c_bad", "[1, 2]"), ("d_good", "\"ok\""))
                    write(joinpath(p, "snippets", "$name.toml"), "name = \"$name\"\ndescription = $desc\ncontent_file = \"$name.jl\"\n")
                    write(joinpath(p, "snippets", "$name.jl"), "@d1 \"bd\"\n")
                end
                for (name, tags) in (("a_baddoc", "3"), ("b_gooddoc", "[\"x\"]"), ("c_baddoc", "[1]"), ("d_gooddoc", "[]"))
                    write(joinpath(p, "docs", "$name.md"), "+++\nname = \"$name\"\nshort = \"s\"\ntags = $tags\n+++\n\ncorps\n")
                end
                @test_logs (:warn, r"a_bad.toml' ignoré") (:warn, r"c_bad.toml' ignoré") (:warn, r"a_baddoc.md' ignorée") match_mode = :any begin
                    Ressac._load_plugins([dir])
                end
                @test Ressac.lookup_snippet("b_good") !== nothing && Ressac.lookup_snippet("d_good") !== nothing
                @test Ressac.lookup_snippet("a_bad") === nothing
                @test Ressac.lookup_doc("b_gooddoc") !== nothing && Ressac.lookup_doc("d_gooddoc") !== nothing
                @test Ressac.lookup_doc("a_baddoc") === nothing
            end
        end
    end

    @testset "P4 — l'ordre des sections est écrit, pas tiré du hachage" begin
        @test Ressac._ordered_sections(["docs", "synthdefs", "snippets", "synths", "julia"]) ==
              ["julia", "synths", "synthdefs", "snippets", "docs"]
        # Une section de plugin (hors liste) vient après, par ordre alphabétique.
        @test Ressac._ordered_sections(["zeta", "docs", "alpha", "julia", "samples"]) ==
              ["julia", "samples", "docs", "alpha", "zeta"]
        # Quel que soit l'ordre d'arrivée.
        for _ in 1:20
            names = Random.shuffle(["samples", "scales", "instruments", "synths", "synthdefs", "snippets", "docs", "julia", "sc_discover"])
            @test Ressac._ordered_sections(names) ==
                  ["julia", "samples", "scales", "instruments", "synths", "synthdefs", "snippets", "docs", "sc_discover"]
        end
        # Et c'est l'ordre dans lequel `load_plugin` appelle les handlers.
        with_clean_registries() do
            seen = String[]
            for sec in (:docs, :synths, :synthdefs, :julia, :zzz)
                Ressac.register_section_handler!(sec, (dir, data, name) -> push!(seen, String(sec)))
            end
            sections = Dict{String,Any}(k => Dict{String,Any}() for k in ("zzz", "docs", "synthdefs", "synths", "julia"))
            Ressac.load_plugin(Ressac.PluginManifest("ordre", "0.1.0", "t", mktempdir(), sections, String[]))
            @test seen == ["julia", "synths", "synthdefs", "docs", "zzz"]
        end
    end

    @testset "P6 — un fichier n'est un synth que s'il en définit un" begin
        mktempdir() do dir
            file(name, text) = (p = joinpath(dir, name); write(p, text); p)
            @test Ressac._looks_like_synth_source(file("a.jl", "@synth :a saw(:freq)\n"))
            @test Ressac._looks_like_synth_source(file("b.jl", "# en-tête\n   @synth :b (freq=220) begin\n  saw(:freq)\nend\n"))
            @test !Ressac._looks_like_synth_source(file("c.jl", "# ce fichier sert à @synth, voir la doc\nhelper(x) = x\n"))
            @test !Ressac._looks_like_synth_source(file("d.jl", "note = \"écrire @synth plus tard\"\n"))
            @test Ressac._looks_like_synth_source(file("e.scd", "SynthDef(\\e, { Out.ar(0, SinOsc.ar) }).add;\n"))
            @test Ressac._looks_like_synth_source(file("f.scd", "(\n  SynthDef(\\f, { }).add; // un SynthDef(\n)\n"))
            @test !Ressac._looks_like_synth_source(file("g.scd", "// exemple : SynthDef(\\g, { })\n~x = 1;\n"))
            @test !Ressac._looks_like_synth_source(file("h.txt", "@synth SynthDef("))
            @test !Ressac._looks_like_synth_source(joinpath(dir, "absent.jl"))
        end
        # Le runner de découverte vit dans son module, pas à plat dans Main.
        @test isdefined(Main, :ScDiscoverer) && Main.ScDiscoverer isa Module
        @test !isdefined(Main, :_handle_sc_discover) && isdefined(Main.ScDiscoverer, :_handle_sc_discover)
    end

    @testset "P2 — recharger les plugins ne s'empile pas sur l'état d'avant" begin
        with_clean_registries() do
            fixtures = joinpath(@__DIR__, "fixtures", "plugins")
            only_inst = mktempdir()
            cp(joinpath(fixtures, "withinst"), joinpath(only_inst, "withinst"))
            Ressac._reset_registries!()
            Ressac._load_plugins([only_inst])
            @test Ressac.instrument_info(:bassy) !== nothing
            # Un second chargement du même plugin : aucun avertissement de « shadow ».
            @test_logs (:info, r"loaded plugin: withinst") match_mode = :all Ressac._load_plugins([only_inst])
            # Et un manifeste édité entre-temps est bien relu.
            manifest = joinpath(only_inst, "withinst", "plugin.toml")
            write(manifest, replace(read(manifest, String), "bassy" => "bassy2"))
            Ressac._reset_registries!()
            Ressac._load_plugins([only_inst])
            @test Ressac.instrument_info(:bassy2) !== nothing && Ressac.instrument_info(:bassy) === nothing
        end
    end
end
