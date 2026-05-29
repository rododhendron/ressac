using Test
using Ressac

@testset "sc-autodiscover" begin
    @testset "_sc_cache_dir defaults to ~/.cache/ressac/plugins/sc-autodiscover" begin
        delete!(ENV, "RESSAC_CACHE_DIR")
        @test Main._sc_cache_dir() ==
            joinpath(homedir(), ".cache", "ressac", "plugins", "sc-autodiscover")
    end

    @testset "_sc_cache_dir honours RESSAC_CACHE_DIR env var" begin
        ENV["RESSAC_CACHE_DIR"] = "/tmp/myressac"
        try
            @test Main._sc_cache_dir() ==
                joinpath("/tmp/myressac", "plugins", "sc-autodiscover")
        finally
            delete!(ENV, "RESSAC_CACHE_DIR")
        end
    end

    @testset "_sc_script_sha256 — same content, same hash" begin
        tmpdir = mktempdir()
        try
            p = joinpath(tmpdir, "discover.scd")
            write(p, "// hello\n")
            h1 = Main._sc_script_sha256(p)
            h2 = Main._sc_script_sha256(p)
            @test h1 == h2
            @test length(h1) == 64
        finally
            rm(tmpdir; recursive=true, force=true)
        end
    end

    @testset "_sc_script_sha256 — one-byte edit changes hash" begin
        tmpdir = mktempdir()
        try
            p = joinpath(tmpdir, "discover.scd")
            write(p, "// hello\n")
            h1 = Main._sc_script_sha256(p)
            write(p, "// hello!\n")
            h2 = Main._sc_script_sha256(p)
            @test h1 != h2
        finally
            rm(tmpdir; recursive=true, force=true)
        end
    end

    @testset "_sc_cache_valid — missing meta → false" begin
        tmpdir = mktempdir()
        try
            scd = joinpath(tmpdir, "discover.scd")
            write(scd, "// noop")
            @test Main._sc_cache_valid(tmpdir, scd; sc_meta = ("3.13.0", 587)) == false
        finally
            rm(tmpdir; recursive=true, force=true)
        end
    end

    @testset "_sc_cache_valid — all match → true" begin
        tmpdir = mktempdir()
        try
            scd = joinpath(tmpdir, "discover.scd")
            write(scd, "// content\n")
            sha = Main._sc_script_sha256(scd)
            meta_path = joinpath(tmpdir, "cache_meta.toml")
            open(meta_path, "w") do io
                println(io, """
                sc_version             = "3.13.0"
                ugen_count             = 587
                generated_at           = "2026-05-29T14:23:11Z"
                discover_script_sha256 = "$sha"
                """)
            end
            @test Main._sc_cache_valid(tmpdir, scd; sc_meta = ("3.13.0", 587)) == true
        finally
            rm(tmpdir; recursive=true, force=true)
        end
    end

    @testset "_sc_cache_valid — sc_version mismatch → false" begin
        tmpdir = mktempdir()
        try
            scd = joinpath(tmpdir, "discover.scd")
            write(scd, "// content\n")
            sha = Main._sc_script_sha256(scd)
            meta_path = joinpath(tmpdir, "cache_meta.toml")
            open(meta_path, "w") do io
                println(io, """
                sc_version             = "3.13.0"
                ugen_count             = 587
                generated_at           = "2026-05-29T14:23:11Z"
                discover_script_sha256 = "$sha"
                """)
            end
            @test Main._sc_cache_valid(tmpdir, scd; sc_meta = ("3.14.0", 587)) == false
        finally
            rm(tmpdir; recursive=true, force=true)
        end
    end

    @testset "_sc_cache_valid — ugen_count mismatch → false" begin
        tmpdir = mktempdir()
        try
            scd = joinpath(tmpdir, "discover.scd")
            write(scd, "// content\n")
            sha = Main._sc_script_sha256(scd)
            meta_path = joinpath(tmpdir, "cache_meta.toml")
            open(meta_path, "w") do io
                println(io, """
                sc_version             = "3.13.0"
                ugen_count             = 587
                generated_at           = "2026-05-29T14:23:11Z"
                discover_script_sha256 = "$sha"
                """)
            end
            @test Main._sc_cache_valid(tmpdir, scd; sc_meta = ("3.13.0", 600)) == false
        finally
            rm(tmpdir; recursive=true, force=true)
        end
    end

    @testset "_sc_cache_valid — script SHA mismatch → false" begin
        tmpdir = mktempdir()
        try
            scd = joinpath(tmpdir, "discover.scd")
            write(scd, "// content\n")
            meta_path = joinpath(tmpdir, "cache_meta.toml")
            open(meta_path, "w") do io
                println(io, """
                sc_version             = "3.13.0"
                ugen_count             = 587
                generated_at           = "2026-05-29T14:23:11Z"
                discover_script_sha256 = "wronghashvalue"
                """)
            end
            @test Main._sc_cache_valid(tmpdir, scd; sc_meta = ("3.13.0", 587)) == false
        finally
            rm(tmpdir; recursive=true, force=true)
        end
    end

    @testset "_sc_cache_valid — corrupted meta TOML → false + warning" begin
        tmpdir = mktempdir()
        try
            scd = joinpath(tmpdir, "discover.scd")
            write(scd, "// content\n")
            meta_path = joinpath(tmpdir, "cache_meta.toml")
            write(meta_path, "not = valid = toml = [[")
            @test_logs (:warn, r"corrupted") begin
                @test Main._sc_cache_valid(tmpdir, scd; sc_meta = ("3.13.0", 587)) == false
            end
        finally
            rm(tmpdir; recursive=true, force=true)
        end
    end

    @testset "_sc_cache_valid — sc_meta=nothing (SC unreachable) → false" begin
        tmpdir = mktempdir()
        try
            scd = joinpath(tmpdir, "discover.scd")
            write(scd, "// content\n")
            sha = Main._sc_script_sha256(scd)
            meta_path = joinpath(tmpdir, "cache_meta.toml")
            open(meta_path, "w") do io
                println(io, """
                sc_version             = "3.13.0"
                ugen_count             = 587
                generated_at           = "2026-05-29T14:23:11Z"
                discover_script_sha256 = "$sha"
                """)
            end
            @test Main._sc_cache_valid(tmpdir, scd; sc_meta = nothing) == false
        finally
            rm(tmpdir; recursive=true, force=true)
        end
    end
end
