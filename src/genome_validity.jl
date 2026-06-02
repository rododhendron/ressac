# src/genome_validity.jl
# validate(g) -> Vector{String} d'erreurs ("" si valide).
# repair!(g)  -> mute g en place pour le rendre valide (la mutation
# mute librement puis on normalise ici — un seul endroit testable).

function _arg_noderef_ids(node::UGenNode)
    [a.id for a in node.args if a isa NodeRef]
end

function validate(g::Genome)::Vector{String}
    errs = String[]
    if g.output_id == 0 || !haskey(g.nodes, g.output_id)
        push!(errs, "no valid output node")
    end
    for (id, n) in g.nodes
        spec = ugen_spec(n.ugen)
        if spec === nothing
            push!(errs, "unknown ugen :$(n.ugen) at node $id")
            continue
        end
        if !(n.rate in spec.rates)
            push!(errs, "node $id rate :$(n.rate) not allowed for :$(n.ugen)")
        end
        if length(n.args) != length(spec.slots)
            push!(errs, "node $id arity $(length(n.args)) != $(length(spec.slots))")
        end
        for ref in _arg_noderef_ids(n)
            haskey(g.nodes, ref) || push!(errs, "dangling NodeRef $ref at node $id")
        end
    end
    _has_cycle(g) && push!(errs, "graph has a cycle")
    return errs
end

function _has_cycle(g::Genome)
    state = Dict{Int,Int}()   # 0 unseen, 1 in-stack, 2 done
    function visit(id)
        haskey(g.nodes, id) || return false
        st = get(state, id, 0)
        st == 1 && return true
        st == 2 && return false
        state[id] = 1
        for ref in _arg_noderef_ids(g.nodes[id])
            visit(ref) && return true
        end
        state[id] = 2
        return false
    end
    return any(visit(id) for id in keys(g.nodes))
end

function repair!(g::Genome)
    # 1. drop dangling refs + cycles by rewriting offending args to
    #    a slot-appropriate constant.
    for (id, n) in g.nodes
        spec = ugen_spec(n.ugen)
        spec === nothing && continue
        # pad / trim arity to the spec
        while length(n.args) < length(spec.slots)
            slot = spec.slots[length(n.args) + 1]
            push!(n.args, ConstArg(slot.default))
        end
        length(n.args) > length(spec.slots) && resize!(n.args, length(spec.slots))
        # fix illegal rate
        n.rate in spec.rates || (n.rate = spec.rates[1])
        # drop dangling refs
        for i in eachindex(n.args)
            a = n.args[i]
            if a isa NodeRef && !haskey(g.nodes, a.id)
                n.args[i] = ConstArg(spec.slots[i].default)
            end
        end
    end
    # 2. break cycles: re-run detection, cutting the back-edge to a const.
    _break_cycles!(g)
    # 3. ensure an output
    if g.output_id == 0 || !haskey(g.nodes, g.output_id)
        g.output_id = isempty(g.nodes) ?
            add_node!(g, :Saw, :ar, Arg[ControlRef(:freq)]) :
            maximum(keys(g.nodes))
    end
    return g
end

function _break_cycles!(g::Genome)
    while _has_cycle(g)
        state = Dict{Int,Int}()
        cut = false
        function visit(id)
            cut && return
            haskey(g.nodes, id) || return
            state[id] = 1
            n = g.nodes[id]
            for i in eachindex(n.args)
                a = n.args[i]
                a isa NodeRef || continue
                if get(state, a.id, 0) == 1
                    spec = ugen_spec(n.ugen)
                    n.args[i] = ConstArg(spec.slots[i].default)
                    cut = true
                    return
                end
                visit(a.id)
                cut && return
            end
            state[id] = 2
        end
        for id in keys(g.nodes)
            visit(id); cut && break
        end
        cut || break
    end
    return g
end
