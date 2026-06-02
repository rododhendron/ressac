# src/genome_operators.jl
# Opérateurs = fonctions (Genome[, rng]) -> mutent en place, puis repair!.
# Paramétrique (étape 1) + structurel/croisement (étape 2, Task 6).
using Random

_copy_genome(g::Genome) = deserialize_genome(serialize_genome(g))

# ── Conservation « biologique » ────────────────────────────────────
# Les nœuds essentiels = l'épine dorsale qui rend le son audible : les
# sources atteignables depuis la sortie + le nœud de sortie. On les mute
# MOINS (comme les gènes essentiels), en laissant la variance aux nœuds
# périphériques/décoratifs.
function _essential_nodes(g::Genome)
    ess = Set{Int}()
    g.output_id == 0 && return ess
    push!(ess, g.output_id)
    for id in _reachable_from_output(g)
        n = g.nodes[id]
        spec = ugen_spec(n.ugen)
        spec === nothing && continue
        (spec.role === :source && n.ugen !== :FbIn) && push!(ess, id)
    end
    return ess
end

# Tire un id de nœud en évitant l'essentiel avec proba `conservation`.
function _pick_node(g::Genome, rng::AbstractRNG; conservation::Float64 = 0.85)
    ids = collect(keys(g.nodes))
    isempty(ids) && return nothing
    if rand(rng) < conservation
        ess = _essential_nodes(g)
        peripheral = [i for i in ids if !(i in ess)]
        isempty(peripheral) || return rand(rng, peripheral)
    end
    return rand(rng, ids)
end

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
    i <= length(spec.slots) || return g   # arité transitoire (avant repair!)
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
        repair!(g)   # normalise entre chaque op : invariants toujours tenus
    end
    repair_audible!(g)   # corrige les muets (source → sortie) ; no-op sinon
    repair!(g)
    return g
end

# ── Opérateurs structurels ─────────────────────────────────────────

# A slot that carries a signal (audio input OR modulatable control) —
# both are valid graft / rewire targets for structural mutation.
_is_signalish(kind::Symbol) = kind === :signal || kind === :audio

function _signal_slot_edges(g::Genome)
    # (node_id, arg_index) où le slot porte un signal.
    out = Tuple{Int,Int}[]
    for (id, n) in g.nodes
        spec = ugen_spec(n.ugen)
        spec === nothing && continue
        for (i, sp) in enumerate(spec.slots)
            _is_signalish(sp.kind) && i <= length(n.args) && push!(out, (id, i))
        end
    end
    return out
end

function _new_node_from_spec!(g::Genome, spec::UGenSpec, first_input::Arg)
    args = Arg[]
    for (i, sp) in enumerate(spec.slots)
        push!(args, (i == 1 && _is_signalish(sp.kind)) ? first_input :
                    ConstArg(sp.default))
    end
    return add_node!(g, spec.name, spec.rates[1], args)
end

function op_insert_node!(g::Genome, rng::AbstractRNG)
    edges = _signal_slot_edges(g)
    isempty(edges) && return g
    (nid, i) = rand(rng, edges)
    cands = vcat(catalog_by_role(:filter), catalog_by_role(:math))
    isempty(cands) && return g
    spec = rand(rng, cands)
    cur = g.nodes[nid].args[i]
    new_id = _new_node_from_spec!(g, spec, cur)
    g.nodes[nid].args[i] = NodeRef(new_id)
    return g
end

function op_remove_node!(g::Genome, rng::AbstractRNG)
    length(g.nodes) <= 1 && return g
    nid = _pick_node(g, rng)              # protège l'épine dorsale
    nid === nothing && return g
    n = g.nodes[nid]
    spec = ugen_spec(n.ugen)
    # Bypass through the node's signal path: prefer its audio input
    # (the real signal it processes), else any signalish slot.
    sig_idxs = [i for (i, sp) in enumerate(spec.slots)
                if _is_signalish(sp.kind) && i <= length(n.args)]
    audio_pos = findfirst(i -> spec.slots[i].kind === :audio, sig_idxs)
    pick = audio_pos !== nothing ? sig_idxs[audio_pos] :
           isempty(sig_idxs) ? nothing : sig_idxs[1]
    bypass = pick === nothing ? ConstArg(0.0) : n.args[pick]
    delete!(g.nodes, nid)
    for other in values(g.nodes), j in eachindex(other.args)
        other.args[j] isa NodeRef && other.args[j].id == nid &&
            (other.args[j] = bypass)
    end
    g.output_id == nid &&
        (g.output_id = bypass isa NodeRef ? bypass.id : 0)
    return g
end

function op_swap_ugen!(g::Genome, rng::AbstractRNG)
    isempty(g.nodes) && return g
    nid = _pick_node(g, rng)              # protège l'épine dorsale
    nid === nothing && return g
    n = g.nodes[nid]
    role = ugen_spec(n.ugen).role
    cands = [s for s in catalog_by_role(role) if s.name !== n.ugen]
    isempty(cands) && return g
    spec = rand(rng, cands)
    n.ugen = spec.name
    n.rate in spec.rates || (n.rate = spec.rates[1])
    return g   # repair! ajuste l'arité
end

function op_rewire!(g::Genome, rng::AbstractRNG)
    edges = _signal_slot_edges(g)
    ids = collect(keys(g.nodes))
    (isempty(edges) || isempty(ids)) && return g
    (nid, i) = rand(rng, edges)
    g.nodes[nid].args[i] = NodeRef(rand(rng, ids))
    return g   # repair! casse un éventuel cycle
end

function op_graft_mod!(g::Genome, rng::AbstractRNG)
    slots = _const_slots(g)
    isempty(slots) && return g
    (nid, i) = rand(rng, slots)
    mods = catalog_by_role(:mod)
    isempty(mods) && return g
    spec = rand(rng, mods)
    mod_id = _new_node_from_spec!(g, spec, ConstArg(spec.slots[1].default))
    g.nodes[nid].args[i] = NodeRef(mod_id)
    return g
end

function op_add_feedback!(g::Genome, rng::AbstractRNG)
    edges = _signal_slot_edges(g)
    isempty(edges) && return g
    # un seul FbIn par génome (SC n'autorise qu'un LocalIn par SynthDef).
    fb_ids = [id for (id, n) in g.nodes if n.ugen === :FbIn]
    fb = isempty(fb_ids) ? add_node!(g, :FbIn, :ar, Arg[]) : first(fb_ids)
    (nid, i) = rand(rng, edges)
    nid == fb && return g                       # ne pas auto-référencer FbIn
    g.nodes[nid].args[i] = NodeRef(fb)
    return g
end

append!(_STRUCT_OPS, Function[op_insert_node!, op_remove_node!,
                              op_swap_ugen!, op_rewire!, op_graft_mod!,
                              op_add_feedback!])

# ── Croisement (swap de sous-graphe) ───────────────────────────────

function _subtree_ids(g::Genome, root::Int, acc = Set{Int}())
    (root in acc || !haskey(g.nodes, root)) && return acc
    push!(acc, root)
    for a in g.nodes[root].args
        a isa NodeRef && _subtree_ids(g, a.id, acc)
    end
    return acc
end

function crossover(a0::Genome, b0::Genome, rng::AbstractRNG)
    child = _copy_genome(b0)
    isempty(a0.nodes) && (repair!(child); return child)
    donor_root = rand(rng, collect(keys(a0.nodes)))
    ids = collect(_subtree_ids(a0, donor_root))
    remap = Dict{Int,Int}()
    for old in ids
        remap[old] = child.next_id
        child.next_id += 1
    end
    for old in ids
        dn = a0.nodes[old]
        newargs = Arg[]
        for arg in dn.args
            push!(newargs, arg isa NodeRef && haskey(remap, arg.id) ?
                           NodeRef(remap[arg.id]) : arg)
        end
        child.nodes[remap[old]] = UGenNode(remap[old], dn.ugen, dn.rate, newargs)
    end
    edges = _signal_slot_edges(child)
    if !isempty(edges)
        (nid, i) = rand(rng, edges)
        child.nodes[nid].args[i] = NodeRef(remap[donor_root])
    end
    repair!(child)
    repair_audible!(child)
    repair!(child)
    return child
end
