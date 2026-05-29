using Test
using TOML
using Ressac

# Same mock used by test_scheduler.jl — captures OSC bytes in a vector
# so tests don't actually open a UDP socket. Redefining locally here
# rather than depending on test_scheduler.jl's load order.
if !isdefined(Main, :MockOSCClient)
    mutable struct MockOSCClient
        sent::Vector{Vector{UInt8}}
    end
    MockOSCClient() = MockOSCClient(Vector{UInt8}[])
    Ressac.send_osc(c::MockOSCClient, bytes::Vector{UInt8}) = push!(c.sent, bytes)
end

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

    @testset "_take_with_timeout — fires when value arrives" begin
        ch = Channel{Int}(1)
        @async (sleep(0.05); put!(ch, 42))
        @test Main._take_with_timeout(ch, 1.0) == 42
    end

    @testset "_take_with_timeout — returns nothing on timeout" begin
        ch = Channel{Int}(1)
        @test Main._take_with_timeout(ch, 0.1) === nothing
    end

    @testset "_sc_meta_roundtrip returns nothing when no scheduler" begin
        # When _LIVE_SCHEDULER[] is nothing, the function must not throw —
        # it returns nothing so _sc_cache_valid treats it as "assume invalid".
        prev = Ressac._LIVE_SCHEDULER[]
        Ressac._LIVE_SCHEDULER[] = nothing
        try
            @test Main._sc_meta_roundtrip(timeout = 0.5) === nothing
        finally
            Ressac._LIVE_SCHEDULER[] = prev
        end
    end

    @testset "_handle_sc_discover — no live session → warn + return" begin
        prev = Ressac._LIVE_SCHEDULER[]
        Ressac._LIVE_SCHEDULER[] = nothing
        try
            @test_logs (:warn, r"no live session") begin
                @test Main._handle_sc_discover("/nonexistent", Dict{String,Any}(),
                                                "sc-discoverer") === nothing
            end
        finally
            Ressac._LIVE_SCHEDULER[] = prev
        end
    end

    @testset "_handle_sc_discover — cache valid → skip discovery" begin
        tmp_root = mktempdir()
        cache_dir = joinpath(tmp_root, "plugins", "sc-autodiscover")
        mkpath(cache_dir)
        ENV["RESSAC_CACHE_DIR"] = tmp_root

        plugin_dir = mktempdir()
        scd_path = joinpath(plugin_dir, "discover.scd")
        write(scd_path, "// fixture content\n")
        sha = Main._sc_script_sha256(scd_path)

        open(joinpath(cache_dir, "cache_meta.toml"), "w") do io
            println(io, """
            sc_version             = "3.13.0"
            ugen_count             = 587
            generated_at           = "2026-05-29T14:23:11Z"
            discover_script_sha256 = "$sha"
            """)
        end

        # Need a non-nothing scheduler so the no-session early return
        # doesn't fire. We don't reach the send_osc call because the
        # cache is valid → early return after the cache check.
        mock = MockOSCClient()
        mock_sched = Ressac.Scheduler(mock; cps = 0.5)
        prev = Ressac._LIVE_SCHEDULER[]
        Ressac._LIVE_SCHEDULER[] = mock_sched
        try
            @test_logs (:info, r"cache fresh") begin
                @test Main._handle_sc_discover(plugin_dir, Dict{String,Any}(),
                    "sc-discoverer";
                    sc_meta_override = ("3.13.0", 587)) === nothing
            end
        finally
            Ressac._LIVE_SCHEDULER[] = prev
            delete!(ENV, "RESSAC_CACHE_DIR")
            rm(tmp_root; recursive=true, force=true)
            rm(plugin_dir; recursive=true, force=true)
        end
    end

    @testset "_write_cache_meta produces a parseable TOML" begin
        tmpdir = mktempdir()
        try
            scd = joinpath(tmpdir, "discover.scd")
            write(scd, "// payload\n")
            Main._write_cache_meta(tmpdir, scd, ("3.13.1", 612))
            meta = TOML.parsefile(joinpath(tmpdir, "cache_meta.toml"))
            @test meta["sc_version"] == "3.13.1"
            @test meta["ugen_count"] == 612
            @test meta["discover_script_sha256"] == Main._sc_script_sha256(scd)
            @test haskey(meta, "generated_at")
        finally
            rm(tmpdir; recursive=true, force=true)
        end
    end
end
