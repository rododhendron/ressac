include(joinpath(@__DIR__, "helpers.jl"))
# Chaque commande `:` a sa ligne de description (palette, complétion).

@testset "une ligne par commande" begin
    verbs = Ressac._all_ex_verbs()
    missing_docs = [v for v in verbs if isempty(Ressac._command_doc(v))]
    @test isempty(missing_docs)
    isempty(missing_docs) || @info "commandes sans description (src/app_command_docs.jl)" missing_docs
    # Rien de décrit qui n'existe plus.
    stale = [v for v in keys(Ressac._COMMAND_DOCS) if !(v in verbs)]
    @test isempty(stale)
    isempty(stale) || @info "descriptions sans commande" stale
    @test Ressac._command_doc(":panic") == Ressac._command_doc("panic") != ""
    # La palette les montre.
    _with_live_app() do app, frame
        Ressac._open_palette!(app)
        it = first(i for i in Ressac._palette_items(app) if i.label == ":mixer")
        @test it.detail == Ressac._command_doc("mixer")
        _key!(app, :escape)
    end
end
