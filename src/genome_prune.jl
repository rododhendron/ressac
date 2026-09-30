# src/genome_prune.jl
# L'élagage : qu'est-ce qui, dans ce graphe, ne s'entend pas ? Deux
# réponses. Des INDICES statiques, gratuits, lus sur la structure (un
# nœud hors de la chaîne, une saturation qui replie un signal déjà
# replié, une source à 0 Hz…). Et une MESURE : chaque nœud retiré à son
# tour, tous les variants rendus hors-ligne en un seul lot, et la
# distance de leurs descripteurs à ceux du son complet — l'impact.
# Le studio sculpt les montre (✂) et `:prune` retire ce qui ne pèse rien.

const _SATURATIONS = (:Tanh, :Clip2, :Fold2, :Round, :Softclip, :Clip, :Fold, :Wrap, :Cubed)
const _OSCILLATORS = (:Saw, :SinOsc, :Pulse, :LFTri, :LFSaw, :VarSaw, :Blip, :Impulse, :SyncSaw)

_const_val(a::Arg) = a isa ConstArg ? a.value : nothing
_ref_id(a::Arg) = a isa NodeRef ? a.id : 0

"""
    static_prune_hints(g) -> Vector{NamedTuple}

Les nœuds dont la structure dit déjà qu'ils ne changent rien (ou
presque), avec la raison. Chaque entrée : `(id, ugen, reason)`.
"""
function static_prune_hints(g::Genome)
    out = NamedTuple{(:id, :ugen, :reason),Tuple{Int,Symbol,String}}[]
    reach = Set(_topo_order(g))
    for id in sort!(collect(keys(g.nodes)))
        n = g.nodes[id]
        # La sortie aussi peut être une saturation redondante ou un mélange
        # avec du silence : la retirer remonte la sortie sur son entrée.
        if !(id in reach)
            push!(out, (id = id, ugen = n.ugen, reason = "hors de la chaîne : jamais entendu"))
            continue
        end
        if n.ugen in _SATURATIONS
            src = get(g.nodes, _ref_id(get(n.args, 1, ConstArg(0.0))), nothing)
            if src !== nothing && src.ugen in _SATURATIONS
                same = src.ugen === n.ugen && length(src.args) == length(n.args) &&
                       all(i -> _const_val(src.args[i]) == _const_val(n.args[i]), 2:length(n.args))
                amt = length(n.args) >= 2 ? _const_val(n.args[2]) : nothing
                if same
                    push!(out, (id = id, ugen = n.ugen, reason = "redondant : son entrée est déjà un $(src.ugen) identique"))
                elseif n.ugen in (:Clip2, :Fold2) && amt !== nothing && amt >= 1
                    push!(out, (id = id, ugen = n.ugen, reason = "sans effet : le signal sort de $(src.ugen) déjà dans ±1"))
                end
            end
        elseif n.ugen in _OSCILLATORS && !isempty(n.args) && _const_val(n.args[1]) == 0.0
            push!(out, (id = id, ugen = n.ugen, reason = "muet : fréquence 0"))
        elseif n.ugen === :MulAdd && length(n.args) == 3 && _const_val(n.args[2]) == 1.0 && _const_val(n.args[3]) == 0.0
            push!(out, (id = id, ugen = n.ugen, reason = "identité : × 1 + 0"))
        elseif n.ugen === :Mix && any(a -> _const_val(a) == 0.0 ||
                                          (s = get(g.nodes, _ref_id(a), nothing); s !== nothing && s.ugen in (:Silent, :Raw)), n.args)
            push!(out, (id = id, ugen = n.ugen, reason = "additionne du silence"))
        end
    end
    return out
end

# Le seam d'analyse (NRT par défaut ; simulé en test).
const _PRUNE_ANALYZE = Ref{Function}(analyze_genomes)

# Le graphe sans `id` (contourné), ou nothing s'il ne se retire pas.
function _without_node(g::Genome, id::Int)
    g2 = _copy_genome(g)
    delete_node!(g2, id) === nothing && return nothing
    (g2.output_id == 0 || isempty(g2.nodes)) && return nothing
    return g2
end

_descr_distance(a, b) = clamp(sqrt(sum(abs2, Float64.(a) .- Float64.(b)) / max(1, length(a))), 0.0, 1.0)

"""
    measure_impacts(g; analyze = _PRUNE_ANALYZE[]) -> Vector{NamedTuple}

L'impact de chaque nœud qu'on peut retirer : la distance (0 = rien ne
change, 1 = tout) entre les descripteurs du son complet et ceux du son
sans ce nœud. Un seul lot de rendu pour tous les variants. Trié du
moins important au plus important. Lève si l'analyse est indisponible.
"""
function measure_impacts(g::Genome; analyze = _PRUNE_ANALYZE[])
    ids = Int[]; variants = Genome[]
    for id in sort!(collect(keys(g.nodes)))
        id == g.output_id && continue
        g2 = _without_node(g, id)
        g2 === nothing && continue
        push!(ids, id); push!(variants, g2)
    end
    isempty(ids) && return NamedTuple{(:id, :ugen, :impact),Tuple{Int,Symbol,Float64}}[]
    descrs = analyze(vcat([g], variants))
    length(descrs) == length(variants) + 1 || error("élagage : l'analyse n'a pas rendu tous les variants")
    base = descrs[1]
    out = [(id = ids[i], ugen = g.nodes[ids[i]].ugen, impact = _descr_distance(base, descrs[i + 1])) for i in eachindex(ids)]
    sort!(out; by = x -> (x.impact, x.id))
    return out
end

"""
    prune!(g, impacts; threshold = 0.02) -> Vector{Int}

Retire, du moins important au plus important, les nœuds dont l'impact
mesuré est sous `threshold`. Renvoie les ids retirés.
"""
function prune!(g::Genome, impacts; threshold::Real = 0.02)
    removed = Int[]
    for r in sort(impacts; by = x -> x.impact)
        r.impact < threshold || break
        haskey(g.nodes, r.id) || continue
        length(g.nodes) > 1 || break
        delete_node!(g, r.id) === nothing && continue
        push!(removed, r.id)
    end
    return removed
end

"""
    prune_report_lines(g; impacts = nothing, measuring = false, note = "") -> Vector{String}

La section « ÉLAGAGE » d'une explication : les indices statiques, puis
les impacts mesurés (les plus faibles d'abord) s'il y en a, ou l'état
de la mesure. Partagée par le studio sculpt et `:explain`.
"""
function prune_report_lines(g::Genome; impacts = nothing, measuring::Bool = false, note::AbstractString = "")
    out = String["", "ÉLAGAGE (ce qui ne s'entend pas)"]
    hints = static_prune_hints(g)
    for h in hints
        push!(out, "  ✂ #$(h.id) $(h.ugen) — $(h.reason)")
    end
    if impacts !== nothing && !isempty(impacts)
        ranked = sort(collect(impacts); by = x -> (x[2], x[1]))
        for (id, imp) in first(ranked, 8)
            haskey(g.nodes, id) || continue
            mark = imp < 0.02 ? "✂" : imp < 0.08 ? "·" : " "
            push!(out, "  $mark #$id $(g.nodes[id].ugen) — impact $(round(imp; digits = 3))")
        end
        push!(out, "  ✂ = inaudible (< 0.02) · d retire un nœud · :prune retire tous les ✂")
    elseif measuring
        push!(out, "  mesure en cours (rendu hors-ligne de chaque nœud retiré)…")
    elseif !isempty(note)
        push!(out, "  élagage mesuré indisponible : $note")
    else
        isempty(hints) && push!(out, "  rien de suspect dans la structure")
        push!(out, "  P (studio) ou :prune (éditeur) mesure l'impact de chaque nœud")
    end
    return out
end

"""
    static_prune!(g) -> Vector{Int}

Retire les nœuds que la structure désigne comme inaudibles (voir
`static_prune_hints`), du dernier au premier. Renvoie les ids retirés.
"""
function static_prune!(g::Genome)
    removed = Int[]
    # Jusqu'au point fixe : retirer une source muette laisse un Mix qui
    # additionne du silence, qui se retire au tour suivant.
    for _ in 1:20
        progressed = false
        for h in sort(static_prune_hints(g); by = x -> -x.id)
            haskey(g.nodes, h.id) || continue
            length(g.nodes) > 1 || break
            if !(h.id in _topo_order(g))
                delete!(g.nodes, h.id); repair!(g)                      # hors chaîne : rien à contourner
            elseif startswith(h.reason, "muet")
                # une source muette : ce qui la lisait lit du silence (0)
                delete!(g.nodes, h.id)
                for other in values(g.nodes), j in eachindex(other.args)
                    other.args[j] isa NodeRef && other.args[j].id == h.id && (other.args[j] = ConstArg(0.0))
                end
                g.output_id == h.id && (g.output_id = 0)
                repair!(g)
            elseif delete_node!(g, h.id) === nothing
                continue
            end
            push!(removed, h.id); progressed = true
        end
        progressed || break
    end
    return removed
end

"""
    replace_synth_block(text, block) -> String

Le texte avec le premier bloc `@synth …` remplacé par `block` : ce qui
est avant (commentaires) et après (autres définitions, ligne
`# ressac-genome`) reste tel quel. Si aucun bloc n'est trouvé, `text`.
"""
function replace_synth_block(text::AbstractString, block::AbstractString)
    s = String(text)
    m = match(r"(?m)^[ \t]*@synth\b", s)
    m === nothing && return s
    from = m.offset
    # `Meta.parse(s, pos)` rend l'expression ET la position juste après :
    # exactement l'étendue du bloc, commentaires suivants exclus.
    ex, nextpos = try Meta.parse(s, from) catch; return s end
    (ex isa Expr && ex.head === :macrocall) || return s
    stop = prevind(s, nextpos)
    while stop >= from && isspace(s[stop]); stop = prevind(s, stop); end
    return s[1:prevind(s, from)] * rstrip(block) * s[nextind(s, stop):end]
end
