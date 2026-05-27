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
