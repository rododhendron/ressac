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
end
