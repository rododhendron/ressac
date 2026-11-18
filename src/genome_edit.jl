# src/genome_edit.jl
# Deux gestes sur le graphe d'un son, utilisés par l'élagage (retirer un
# nœud en laissant passer son signal) et par la mutation (greffer un
# modulateur sur un réglage).

# La 1re VRAIE entrée audio (`kind === :audio`) d'un nœud, ou nothing. On
# exclut les slots `:signal` (freq modulable d'une source…) : bypasser/recâbler
# à travers eux n'a pas de sens (une source pure n'a pas d'entrée audio).
function _audio_input_slot(n::UGenNode)
    spec = ugen_spec(n.ugen)
    spec === nothing && return nothing
    return findfirst(i -> i <= length(n.args) && spec.slots[i].kind === :audio,
                     1:length(spec.slots))
end

# L'entrée par laquelle on contourne un nœud qu'on retire : son entrée
# audio, sinon — pour une mise en forme ou un mélange (rôle :math), dont
# l'entrée est déclarée « signal » — le premier nœud branché dessus.
function _bypass_input_slot(n::UGenNode)
    si = _audio_input_slot(n)
    si === nothing || return si
    # Une forme méthode SC (`(x).round(q)`, `.fold2(a)`…) : le receveur est
    # toujours le premier argument, même quand c'est un contrôle.
    haskey(SynthDSL._UGEN_METHOD_FORMS, n.ugen) && !isempty(n.args) && return 1
    spec = ugen_spec(n.ugen)
    (spec !== nothing && spec.role === :math) || return nothing
    return findfirst(a -> a isa NodeRef, n.args)
end

# Retire `node_id` en faisant PASSER son signal d'entrée à sa place : tout ce
# qui le lisait lit son entrée (court-circuit). Une source pure n'a rien à
# laisser passer : refusé. Rend le nœud qui a pris la place, ou `nothing`.
function delete_node!(g::Genome, node_id::Int)
    (haskey(g.nodes, node_id) && length(g.nodes) > 1) || return nothing
    n = g.nodes[node_id]
    si = _bypass_input_slot(n)
    si === nothing && return nothing            # source pure → pas de contournement
    bypass = n.args[si]
    delete!(g.nodes, node_id)
    for other in values(g.nodes), j in eachindex(other.args)
        other.args[j] isa NodeRef && other.args[j].id == node_id &&
            (other.args[j] = bypass)
    end
    g.output_id == node_id && (g.output_id = bypass isa NodeRef ? bypass.id : 0)
    repair!(g)
    return bypass isa NodeRef ? bypass.id : g.output_id
end

# Remplace le réglage `arg_index` (un nombre) de `node_id` par un modulateur
# (rôle :mod, le premier du catalogue). Rend l'id du modulateur, ou `nothing`.
function graft_mod!(g::Genome, node_id::Int; arg_index::Int = 0)
    haskey(g.nodes, node_id) || return nothing
    n = g.nodes[node_id]
    (1 <= arg_index <= length(n.args) && n.args[arg_index] isa ConstArg) || return nothing
    mods = catalog_by_role(:mod)
    isempty(mods) && return nothing
    spec = ugen_spec(first(sort!([s.name for s in mods])))
    spec === nothing && return nothing
    mod_id = _new_node_from_spec!(g, spec, ConstArg(spec.slots[1].default))
    g.nodes[node_id].args[arg_index] = NodeRef(mod_id)
    repair!(g)
    return mod_id
end
