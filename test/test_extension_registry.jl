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
end
