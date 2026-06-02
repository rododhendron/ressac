# src/ga_analysis.jl
# Analyse de population : distance génétique, clustering par proximité,
# distribution des gènes (UGens). Pur — aucune dépendance SC/UI.

function _genome_ugen_counts(g::Genome)
    counts = Dict{Symbol,Int}()
    for n in values(g.nodes)
        counts[n.ugen] = get(counts, n.ugen, 0) + 1
    end
    return counts
end

"""
    genome_distance(a, b) -> Float64

Crude genetic distance: L1 over the UGen multiset + a structural-size
term. 0 means identical UGen makeup + size. Enough to colour the grid
by proximity and find clusters among ~9 candidates.
"""
function genome_distance(a::Genome, b::Genome)
    fa = _genome_ugen_counts(a)
    fb = _genome_ugen_counts(b)
    d = 0.0
    for k in union(keys(fa), keys(fb))
        d += abs(get(fa, k, 0) - get(fb, k, 0))
    end
    d += abs(length(a.nodes) - length(b.nodes)) * 0.5
    return d
end

"""
    cluster_population(cands; threshold=1.5) -> Vector{Int}

Assign a cluster id (1-based, in order of appearance) to each candidate
by union-find: two candidates closer than `threshold` join the same
cluster. Deterministic, no RNG.
"""
function cluster_population(cands::Vector{Candidate}; threshold::Float64 = 1.5)
    n = length(cands)
    n == 0 && return Int[]
    parent = collect(1:n)
    find(x) = parent[x] == x ? x : (parent[x] = find(parent[x]))
    for i in 1:n, j in (i + 1):n
        if genome_distance(cands[i].genome, cands[j].genome) <= threshold
            parent[find(i)] = find(j)
        end
    end
    label = Dict{Int,Int}()
    out = Int[]
    for i in 1:n
        r = find(i)
        haskey(label, r) || (label[r] = length(label) + 1)
        push!(out, label[r])
    end
    return out
end

"""
    genome_feature_vec(g) -> Vector{Float64}

Fixed-length numeric features of a genome for the preference surrogate:
one count per catalogued UGen (sorted, stable order) + node count +
depth-ish (output's arg fan-in) + has-feedback flag. The order is stable
across calls because it follows `sort(keys(UGEN_CATALOG))`.
"""
function genome_feature_vec(g::Genome)
    names = sort!(collect(keys(UGEN_CATALOG)))
    counts = _genome_ugen_counts(g)
    feat = Float64[get(counts, nm, 0) for nm in names]
    push!(feat, Float64(length(g.nodes)))
    fanin = (g.output_id != 0 && haskey(g.nodes, g.output_id)) ?
            count(a -> a isa NodeRef, g.nodes[g.output_id].args) : 0
    push!(feat, Float64(fanin))
    push!(feat, any(n -> n.ugen === :FbIn, values(g.nodes)) ? 1.0 : 0.0)
    return feat
end

"""
    gene_distribution(cands) -> Vector{Pair{Symbol,Int}}

Count UGen occurrences across the whole population, most common first.
"""
function gene_distribution(cands::Vector{Candidate})
    counts = Dict{Symbol,Int}()
    for c in cands
        for n in values(c.genome.nodes)
            counts[n.ugen] = get(counts, n.ugen, 0) + 1
        end
    end
    return sort!(collect(counts); by = x -> (-x[2], String(x[1])))
end
