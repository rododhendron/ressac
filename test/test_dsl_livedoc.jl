# Livedoc et bout en bout du DSL sur une collection de synths.
#
# 1. Chaque nom exporté par SynthDSL a une doc vivante (K, pane DOC).
# 2. Collection système (test/fixtures/synths/*.jl + recettes DSL de la
#    librairie) : le texte se parse, se compile en SynthDef (sans rien
#    envoyer), donne un génome, s'exporte et se relit ; chaque fonction
#    du DSL qu'il emploie a sa doc, et la pane DOC ne répond jamais
#    « aucune entrée » sur elle.
# 3. La même chose sur plugins/user-synths quand RESSAC_USER_SYNTHS_TESTS=1
#    (`just test-user-synths`) — la suite par défaut ne dépend pas des
#    fichiers de l'utilisateur.
using Test
using Ressac
using Tachikoma

const _LD_S = Ressac.SynthDSL

# Identifiants appelés dans un texte DSL qui sont des fonctions de SynthDSL.
function _ld_dsl_calls(text::AbstractString)
    out = String[]
    code = replace(text, r"#[^\n]*" => "")          # pas les commentaires (« ring-mod (Bode » n'appelle pas mod)
    for mt in eachmatch(r"(?<![\w.:])([A-Za-z_]\w*)\s*\(", code)
        w = String(mt.captures[1])
        w in out && continue
        sym = Symbol(w)
        isdefined(_LD_S, sym) || continue
        getfield(_LD_S, sym) isa Function || continue
        push!(out, w)
    end
    return out
end

# Compile le texte (capture drone : rien n'est envoyé) et rend (nom, source, params).
function _ld_compile(text::AbstractString)
    cap = Any[]
    Ressac._DRONE_CAPTURE[] = cap
    try
        Core.eval(_LD_S, _LD_S._dsl_parse_all(text))
    finally
        Ressac._DRONE_CAPTURE[] = nothing
    end
    return cap
end

function _ld_check_corpus(label::AbstractString, items::Vector{Pair{String,String}})
    @testset "$label" begin
        for (name, text) in items
            @testset "$name" begin
                cap = _ld_compile(text)
                @test !isempty(cap)
                isempty(cap) && continue
                (sc_name, src, eff) = cap[end]
                @test occursin("SynthDef(\\$(sc_name)_drone", src)
                @test haskey(eff, :freq)
                # génome + export + relecture
                g = Ressac.genome_from_dsl(text)
                @test g !== nothing
                if g !== nothing
                    out = Ressac.render_dsl(g, sc_name)
                    g2 = Ressac.genome_from_dsl(out)
                    @test g2 !== nothing
                    # même son : le SynthDef SC rendu est identique (les nœuds
                    # qui n'atteignent pas la sortie ne comptent pas)
                    g2 === nothing || @test Ressac.render_synthdef(g2, sc_name) == Ressac.render_synthdef(g, sc_name)
                    @test !isempty(_ld_compile(out))
                end
                # chaque fonction du DSL employée a sa doc, et la pane DOC la trouve
                for w in _ld_dsl_calls(text)
                    @test Ressac._lookup_livedoc(w) !== nothing
                    lines = Ressac._doc_pane_lines(w, 60)
                    @test !any(l -> occursin("aucune entrée", Ressac._md_text(l)), lines)
                end
            end
        end
    end
end

@testset "livedoc — chaque nom exporté par SynthDSL est documenté" begin
    missing = String[]
    for n in names(_LD_S)
        w = String(n)
        w == "SynthDSL" && continue
        Ressac._lookup_livedoc(w) === nothing && push!(missing, w)
    end
    @test isempty(missing)
    isempty(missing) || @info "SynthDSL sans doc vivante" missing
    # les cas signalés
    for w in ("fold2", "clip2", "round_q", "tanh_drive", "safe", "feedback", "midicps")
        d = Ressac._lookup_livedoc(w)
        @test d !== nothing
        # une fiche de plugin (le `feedback` de SuperDirt) passe avant l'entrée DSL : c'est voulu
        Ressac.lookup_doc(w) === nothing && @test occursin(w, something(d, ""))
    end
end

_ld_fixture_items() = Pair{String,String}[
    f => read(joinpath(@__DIR__, "fixtures", "synths", f), String)
    for f in sort(readdir(joinpath(@__DIR__, "fixtures", "synths"))) if endswith(f, ".jl")]

_ld_library_items() = Pair{String,String}[
    e.name => e.source for e in Ressac._SYNTH_LIBRARY if e.mode === :dsl && occursin("@synth", e.source)]

@testset "collection système" begin
    items = _ld_fixture_items()
    @test length(items) >= 20
    old = Ressac._LIVE_SCHEDULER[]
    Ressac._LIVE_SCHEDULER[] = nothing
    try
        _ld_check_corpus("fixtures/synths", items)
        _ld_check_corpus("librairie DSL", _ld_library_items())
    finally
        Ressac._LIVE_SCHEDULER[] = old
    end
end

if get(ENV, "RESSAC_USER_SYNTHS_TESTS", "") == "1"
    dir = joinpath(pwd(), "plugins", "user-synths")
    items = isdir(dir) ? Pair{String,String}[f => read(joinpath(dir, f), String)
                                           for f in sort(readdir(dir)) if endswith(f, ".jl")] :
                         Pair{String,String}[]
    @info "synths de l'utilisateur" n = length(items)
    _ld_check_corpus("plugins/user-synths", items)
end

# Le SC que le texte exporté compile (ce que l'éditeur envoie à SC) doit
# donner de l'audio à chaque entrée audio : un filtre qui reçoit un
# contrôle nu (`BLowShelf.ar(freq, …)`) est refusé par sclang (« input is
# not audio rate ») et l'éditeur reste muet alors que l'explorateur joue.
function _ld_bare_audio_inputs(src::AbstractString)
    bad = String[]
    for mt in eachmatch(r"\b([A-Z]\w*)\.ar\(\s*([A-Za-z_]\w*|[0-9.]+)\s*[,)]", src)
        u = Symbol(mt.captures[1])
        spec = Ressac.ugen_spec(u)
        spec === nothing && continue
        isempty(spec.slots) && continue
        spec.slots[1].kind === :audio || continue
        push!(bad, mt.match)
    end
    return bad
end

@testset "export → le SC de l'éditeur donne de l'audio à chaque entrée audio" begin
    @test _ld_bare_audio_inputs("RLPF.ar(freq, 800, 0.3)") == ["RLPF.ar(freq,"]
    @test isempty(_ld_bare_audio_inputs("RLPF.ar(DC.ar(freq), 800, 0.3)"))
    @test isempty(_ld_bare_audio_inputs("SinOsc.ar(freq, 0)"))             # une source : freq n'est pas audio
    old = Ressac._LIVE_SCHEDULER[]
    Ressac._LIVE_SCHEDULER[] = nothing
    try
        for (name, text) in vcat(_ld_fixture_items(), _ld_library_items())
            g = Ressac.genome_from_dsl(text)
            g === nothing && continue
            out = Ressac.render_dsl(g, :x)
            editor_sc = Core.eval(_LD_S, _LD_S._dsl_parse_all(out))
            @testset "$name" begin
                @test isempty(_ld_bare_audio_inputs(editor_sc))
            end
        end
    finally
        Ressac._LIVE_SCHEDULER[] = old
    end
end
