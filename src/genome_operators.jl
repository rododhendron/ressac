# src/genome_operators.jl
# Opérateurs = fonctions (Genome[, rng]) -> mutent en place, puis repair!.
# Paramétrique (étape 1) + structurel/croisement (étape 2, Task 6).
using Random

_copy_genome(g::Genome) = deserialize_genome(serialize_genome(g))

function _const_slots(g::Genome)
    out = Tuple{Int,Int}[]   # (node_id, arg_index)
    for (id, n) in g.nodes
        for (i, a) in enumerate(n.args)
            a isa ConstArg && push!(out, (id, i))
        end
    end
    return out
end

function op_perturb_const!(g::Genome, rng::AbstractRNG; radius::Float64 = 0.5)
    slots = _const_slots(g)
    isempty(slots) && return g
    (nid, i) = rand(rng, slots)
    n = g.nodes[nid]
    spec = ugen_spec(n.ugen)
    sp = spec.slots[i]
    span = sp.hi - sp.lo
    cur = n.args[i].value
    new = cur + randn(rng) * span * 0.25 * radius
    n.args[i] = ConstArg(clamp(new, sp.lo, sp.hi))
    return g
end

function op_change_rate!(g::Genome, rng::AbstractRNG)
    ids = collect(keys(g.nodes))
    isempty(ids) && return g
    nid = rand(rng, ids)
    n = g.nodes[nid]
    spec = ugen_spec(n.ugen)
    length(spec.rates) > 1 && (n.rate = rand(rng, spec.rates))
    return g
end

# Mutation = applique 1..k opérateurs selon le rayon, puis répare.
# radius 0 → uniquement paramétrique (1 perturbation).
# radius>0 → mélange paramétrique + structurel (Task 6 enrichit _STRUCT_OPS).
const _PARAM_OPS = Function[op_perturb_const!, op_change_rate!]
const _STRUCT_OPS = Function[]   # rempli en Task 6

function mutate(g0::Genome, rng::AbstractRNG; radius::Float64 = 0.5)
    g = _copy_genome(g0)
    n_ops = 1 + floor(Int, radius * 3)
    for _ in 1:n_ops
        use_struct = !isempty(_STRUCT_OPS) && rand(rng) < radius
        op = rand(rng, use_struct ? _STRUCT_OPS : _PARAM_OPS)
        if op === op_perturb_const!
            op(g, rng; radius = radius)
        else
            op(g, rng)
        end
    end
    repair!(g)
    return g
end
