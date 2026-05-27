using Test
using Ressac

@testset "extension_registry" begin
    @testset "DocEntry construction + register + lookup" begin
        # Clear registry between tests — we don't want cross-test pollution.
        empty!(Ressac._DOCS)
        e = Ressac.DocEntry("gain", "Volume multiplier.",
                            [:control], [:val], ["@d1 :bd |> gain(0.5)"],
                            "", "core", "/tmp/gain.md")
        Ressac.register_doc!(e)
        got = Ressac.lookup_doc("gain")
        @test got !== nothing
        @test got.name == "gain"
        @test got.short == "Volume multiplier."
        @test got.tags == [:control]
        @test got.examples == ["@d1 :bd |> gain(0.5)"]
        @test got.plugin == "core"
    end

    @testset "lookup_doc returns nothing for unknown name" begin
        empty!(Ressac._DOCS)
        @test Ressac.lookup_doc("nonexistent") === nothing
    end

    @testset "register_doc! last-wins with warning on conflict" begin
        empty!(Ressac._DOCS)
        e1 = Ressac.DocEntry("foo", "first", Symbol[], Symbol[], String[],
                             "", "plugA", "/a/foo.md")
        e2 = Ressac.DocEntry("foo", "second", Symbol[], Symbol[], String[],
                             "", "plugB", "/b/foo.md")
        Ressac.register_doc!(e1)
        @test_logs (:warn, r"shadowed by plugin 'plugB'") begin
            Ressac.register_doc!(e2)
        end
        @test Ressac.lookup_doc("foo").plugin == "plugB"
    end

    @testset "list_docs sorts alphabetically" begin
        empty!(Ressac._DOCS)
        for n in ["zebra", "alpha", "mango"]
            Ressac.register_doc!(Ressac.DocEntry(n, "", Symbol[], Symbol[],
                                                 String[], "", "core", ""))
        end
        @test Ressac.list_docs() == ["alpha", "mango", "zebra"]
    end

    @testset "SnippetEntry construction + register + lookup" begin
        empty!(Ressac._SNIPPET_REGISTRY)
        e = Ressac.SnippetEntry(
            "techno-classic", :starter,
            "Four-on-the-floor", [:techno, :rhythm],
            String[], String[],
            "@d1 p\"bd*4\" |> gain(0.5)\n",
            Any[], "core", "/tmp/techno-classic.toml")
        Ressac.register_snippet!(e)
        got = Ressac.lookup_snippet("techno-classic")
        @test got !== nothing
        @test got.mode === :starter
        @test got.tags == [:techno, :rhythm]
        @test got.resolved_content == "@d1 p\"bd*4\" |> gain(0.5)\n"
    end

    @testset "list_snippets returns all, list_starters filters" begin
        empty!(Ressac._SNIPPET_REGISTRY)
        Ressac.register_snippet!(Ressac.SnippetEntry(
            "zeta", :starter, "", Symbol[], String[], String[],
            "", Any[], "core", ""))
        Ressac.register_snippet!(Ressac.SnippetEntry(
            "alpha", :block, "", Symbol[], String[], String[],
            "", Any[], "core", ""))
        Ressac.register_snippet!(Ressac.SnippetEntry(
            "mango", :starter, "", Symbol[], String[], String[],
            "", Any[], "core", ""))
        @test Ressac.list_snippets() == ["alpha", "mango", "zeta"]
        @test Ressac.list_starters() == ["mango", "zeta"]
    end

    @testset "register_snippet! last-wins with warning on conflict" begin
        empty!(Ressac._SNIPPET_REGISTRY)
        e1 = Ressac.SnippetEntry("foo", :block, "v1", Symbol[],
                                  String[], String[], "a", Any[], "plugA", "")
        e2 = Ressac.SnippetEntry("foo", :block, "v2", Symbol[],
                                  String[], String[], "b", Any[], "plugB", "")
        Ressac.register_snippet!(e1)
        @test_logs (:warn, r"snippet 'foo' shadowed by plugin 'plugB'") begin
            Ressac.register_snippet!(e2)
        end
        @test Ressac.lookup_snippet("foo").plugin == "plugB"
    end

    @testset "_load_snippet_toml — valid manifest + valid sidecar" begin
        empty!(Ressac._SNIPPET_REGISTRY)
        empty!(Ressac._SNIPPET_RAW)
        fixture_dir = joinpath(@__DIR__, "fixtures", "registry")
        toml_path = joinpath(fixture_dir, "good_snippet.toml")
        e = Ressac._load_snippet_toml(toml_path, "testplug")
        @test e !== nothing
        @test e.name == "fixture-good"
        @test e.mode === :block
        @test e.tags == [:fixture, :test]
        @test e.plugin == "testplug"
        @test e.resolved_content == ""
        @test occursin("x = 1 + 2", Ressac._SNIPPET_RAW[e.name].own_content)
        @test isempty(e.includes)
    end

    @testset "_load_snippet_toml — sidecar with syntax error skipped" begin
        empty!(Ressac._SNIPPET_RAW)
        fixture_dir = joinpath(@__DIR__, "fixtures", "registry")
        toml_path = joinpath(fixture_dir, "bad_syntax.toml")
        @test_logs (:warn, r"syntax error") begin
            e = Ressac._load_snippet_toml(toml_path, "testplug")
            @test e === nothing
        end
    end

    @testset "_load_snippet_toml — missing sidecar skipped" begin
        empty!(Ressac._SNIPPET_RAW)
        tmpdir = mktempdir()
        try
            open(joinpath(tmpdir, "orphan.toml"), "w") do io
                println(io, """name = "orphan"
                mode = "block"
                description = "missing sidecar"
                content_file = "does_not_exist.jl"
                """)
            end
            @test_logs (:warn, r"sidecar.*does_not_exist") begin
                e = Ressac._load_snippet_toml(joinpath(tmpdir, "orphan.toml"),
                                              "testplug")
                @test e === nothing
            end
        finally
            rm(tmpdir; recursive=true, force=true)
        end
    end

    @testset "_resolve_snippet_includes! — two-snippet chain" begin
        empty!(Ressac._SNIPPET_REGISTRY)
        empty!(Ressac._SNIPPET_RAW)
        Ressac._SNIPPET_REGISTRY["B"] = Ressac.SnippetEntry(
            "B", :block, "lib", Symbol[], String[], String[],
            "", Any[], "core", "")
        Ressac._SNIPPET_RAW["B"] = (own_content = "B_content\n", includes = String[])

        Ressac._SNIPPET_REGISTRY["A"] = Ressac.SnippetEntry(
            "A", :starter, "main", Symbol[], String[], ["B"],
            "", Any[], "core", "")
        Ressac._SNIPPET_RAW["A"] = (own_content = "A_content\n", includes = ["B"])

        Ressac._resolve_snippet_includes!()
        a = Ressac.lookup_snippet("A")
        @test occursin("B_content", a.resolved_content)
        @test occursin("A_content", a.resolved_content)
        b_idx = findfirst("B_content", a.resolved_content)
        a_idx = findfirst("A_content", a.resolved_content)
        @test b_idx[1] < a_idx[1]
    end

    @testset "_resolve_snippet_includes! — diamond, no duplicate" begin
        empty!(Ressac._SNIPPET_REGISTRY)
        empty!(Ressac._SNIPPET_RAW)
        for (n, inc) in (("D", String[]), ("B", ["D"]), ("C", ["D"]),
                          ("A", ["B", "C"]))
            Ressac._SNIPPET_REGISTRY[n] = Ressac.SnippetEntry(
                n, :block, "", Symbol[], String[], inc,
                "", Any[], "core", "")
            Ressac._SNIPPET_RAW[n] = (own_content = "$(n)_content\n",
                                       includes = inc)
        end
        Ressac._resolve_snippet_includes!()
        a = Ressac.lookup_snippet("A").resolved_content
        @test length(collect(eachmatch(r"D_content", a))) == 1
    end

    @testset "_resolve_snippet_includes! — missing include warns + fallback" begin
        empty!(Ressac._SNIPPET_REGISTRY)
        empty!(Ressac._SNIPPET_RAW)
        Ressac._SNIPPET_REGISTRY["A"] = Ressac.SnippetEntry(
            "A", :block, "", Symbol[], String[], ["ghost"],
            "", Any[], "core", "")
        Ressac._SNIPPET_RAW["A"] = (own_content = "A_content\n",
                                     includes = ["ghost"])
        @test_logs (:warn, r"missing include 'ghost'") begin
            Ressac._resolve_snippet_includes!()
        end
        a = Ressac.lookup_snippet("A")
        @test a.resolved_content == "A_content\n"
    end

    @testset "_resolve_snippet_includes! — cycle detected + fallback" begin
        empty!(Ressac._SNIPPET_REGISTRY)
        empty!(Ressac._SNIPPET_RAW)
        Ressac._SNIPPET_REGISTRY["A"] = Ressac.SnippetEntry(
            "A", :block, "", Symbol[], String[], ["B"],
            "", Any[], "core", "")
        Ressac._SNIPPET_RAW["A"] = (own_content = "A_content\n",
                                     includes = ["B"])
        Ressac._SNIPPET_REGISTRY["B"] = Ressac.SnippetEntry(
            "B", :block, "", Symbol[], String[], ["A"],
            "", Any[], "core", "")
        Ressac._SNIPPET_RAW["B"] = (own_content = "B_content\n",
                                     includes = ["A"])
        @test_logs (:warn, r"cycle") begin
            Ressac._resolve_snippet_includes!()
        end
        @test Ressac.lookup_snippet("A").resolved_content == "A_content\n"
        @test Ressac.lookup_snippet("B").resolved_content == "B_content\n"
    end

    @testset "_resolve_snippet_includes! — requires_plugins propagates" begin
        empty!(Ressac._SNIPPET_REGISTRY)
        empty!(Ressac._SNIPPET_RAW)
        Ressac._SNIPPET_REGISTRY["lib"] = Ressac.SnippetEntry(
            "lib", :block, "", Symbol[], ["foo"], String[],
            "", Any[], "core", "")
        Ressac._SNIPPET_RAW["lib"] = (own_content = "L\n", includes = String[])
        Ressac._SNIPPET_REGISTRY["main"] = Ressac.SnippetEntry(
            "main", :starter, "", Symbol[], String[], ["lib"],
            "", Any[], "core", "")
        Ressac._SNIPPET_RAW["main"] = (own_content = "M\n", includes = ["lib"])
        Ressac._resolve_snippet_includes!()
        @test "foo" in Ressac.lookup_snippet("main").requires_plugins
    end

    @testset "parse_frontmatter — TOML between +++ fences" begin
        src = """
        +++
        name = "foo"
        short = "tooltip"
        tags = ["a", "b"]
        +++

        # Header
        body line 1
        """
        fm, body = Ressac._parse_frontmatter(src)
        @test fm["name"] == "foo"
        @test fm["short"] == "tooltip"
        @test fm["tags"] == ["a", "b"]
        @test occursin("body line 1", body)

        fm2, body2 = Ressac._parse_frontmatter("just body\nno fences\n")
        @test isempty(fm2)
        @test body2 == "just body\nno fences\n"

        fm3, body3 = Ressac._parse_frontmatter("+++\n+++\nbody\n")
        @test isempty(fm3)
        @test body3 == "body\n"

        @test_logs (:warn, r"unterminated frontmatter") begin
            fm4, body4 = Ressac._parse_frontmatter("+++\nname = \"x\"\nno end\n")
            @test isempty(fm4)
        end
    end
end
