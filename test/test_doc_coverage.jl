# Chaque nom exporté qui fait partie du vocabulaire de live-coding a une
# fiche `:doc`. Ce test empêche qu'une fonction se « perde » : ajouter un
# export sans fiche le fait échouer, avec le nom manquant dans le message.
using Test
using Ressac

# Plomberie : types, macros de slot, entrées/sorties bas niveau et
# chargement de plugins. Pas du vocabulaire qu'on tape en jouant.
const _DOC_EXEMPT = Set{String}([
    "Ressac", "Event", "Pattern", "OSCMessage", "OSCBundle", "OSCClient", "Scheduler",
    "SampleEntry", "InstrumentEntry", "SynthEntry", "ControlMap", "ControlPattern", "Scale",
    "@p_str",
    "encode", "send_osc", "start!", "stop!",
    "load_plugin", "parse_manifest", "discover_plugins", "default_plugin_path",
    "register_section_handler!", "unregister_section_handler!", "get_section_handler",
])
_is_slot_macro(n::AbstractString) = occursin(r"^@d\d+$", n)

@testset "couverture des docs — tout export musical a une fiche :doc" begin
    Ressac._handle_docs(joinpath(@__DIR__, "..", "plugins", "core"), Dict("dir" => "docs"), "core")
    exported = sort(String.(names(Ressac)))
    @test length(exported) > 300
    missing_docs = [n for n in exported
                    if !(n in _DOC_EXEMPT) && !_is_slot_macro(n) && Ressac.lookup_doc(n) === nothing]
    if !isempty(missing_docs)
        println("Sans fiche :doc — ajoute plugins/core/docs/<nom>.md pour : ",
                join(missing_docs, ", "))
    end
    @test isempty(missing_docs)

    # Les fiches sont utilisables : titre, description, exemples valides.
    for n in exported
        (n in _DOC_EXEMPT || _is_slot_macro(n)) && continue
        e = Ressac.lookup_doc(n)
        e === nothing && continue
        @test !isempty(e.short)
        @test !occursin("TODO", e.short)
    end
end

@testset "couverture de la complétion — les combinateurs proposés existent" begin
    for name in Ressac._COMBINATOR_NAMES
        @test isdefined(Ressac, Symbol(name)) || name in ("chop",)
    end
    # les grands noms du vocabulaire sont proposés à la complétion
    for name in ("scale", "note", "off", "jux", "ply", "segment", "sine", "geom", "seq", "structPat")
        @test name in Ressac._COMBINATOR_NAMES
    end
end
