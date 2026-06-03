# src/ga_targeting.jl
# Boucle « grand pool → top-k » : l'évaluation acoustique étant silencieuse
# et hors-ligne (NRT), le coût de génération devient négligeable. On génère
# BEAUCOUP de candidats, on les mesure tous, puis on n'expose que les
# meilleurs (par role_fit en mode A). Les descripteurs mesurés sont rangés
# dans pop.state[:descr] (id → vecteur) et pilotent _eff (cf. ga_engine).

_descr_store(pop::Population) =
    get!(pop.state, :descr, Dict{Int,Vector{Float64}}())::Dict{Int,Vector{Float64}}

# Génère un grand pool d'enfants depuis les parents courants (favoris +
# rôle), SANS remplacer la population. Réutilise élitisme/croisement/mutation.
function generate_pool(pop::Population, rng::AbstractRNG, n::Int)
    favored = sort([c for c in pop.candidates if _eff(pop, c) > 0]; by = c -> -_eff(pop, c))
    parents = isempty(favored) ? Candidate[Candidate(pop.base, 0.0)] : favored
    out = Candidate[]
    while length(out) < n
        if length(parents) >= 2 && rand(rng) < pop.crossover_prob
            pa = rand(rng, parents); pb = rand(rng, parents)
            push!(out, _spawn!(pop, crossover(pa.genome, pb.genome, rng),
                               "pool ×#$(pa.id)×#$(pb.id)", [pa.id, pb.id]))
        else
            pa = rand(rng, parents)
            push!(out, _spawn!(pop, _mutate(pop, pa.genome, rng), "pool #$(pa.id)", [pa.id]))
        end
    end
    return out
end

# Range les candidats par poids effectif décroissant (rôle compris) et
# garde les k meilleurs. Suppose les descripteurs déjà mesurés/rangés.
function rank_topk(pop::Population, cands::Vector{Candidate}, k::Int)
    sorted = sort(cands; by = c -> -_eff(pop, c))
    return sorted[1:min(k, length(sorted))]
end

# ── Mode C : tags d'exemples (affinage supervisé du rôle actif) ────
# Range le descripteur mesuré du candidat i comme exemple + (positive) ou
# − du rôle courant ; effective_role (ga_engine) s'en sert pour déplacer la
# cible. Renvoie false si pas de rôle actif / pas de mesure.
function tag_example!(pop::Population, i::Int, positive::Bool)
    rname = get(pop.state, :role, nothing)
    rname === nothing && return false
    1 <= i <= length(pop.candidates) || return false
    d = get(_descr_store(pop), pop.candidates[i].id, nothing)
    d === nothing && return false
    ex = get!(pop.state, :role_examples, Dict{Symbol,Any}())
    e = get!(ex, rname, (pos = Vector{Vector{Float64}}(), neg = Vector{Vector{Float64}}()))
    push!(positive ? e.pos : e.neg, copy(d))
    return true
end

# ── Mode B : clustering de l'espace descripteur mesuré ─────────────
_descr_dist(a, b) = sqrt(sum((a[i] - b[i])^2 for i in 1:min(length(a), length(b)); init = 0.0))

# Clustering glouton par seuil (familles timbrales émergentes).
function cluster_descriptors(descrs::Vector{<:AbstractVector}; threshold::Float64 = 0.3)
    labels = zeros(Int, length(descrs))
    centroids = Vector{Vector{Float64}}()
    for (i, d) in enumerate(descrs)
        best = 0; bd = Inf
        for (ci, c) in enumerate(centroids)
            dist = _descr_dist(d, c)
            dist < bd && (bd = dist; best = ci)
        end
        if best == 0 || bd > threshold
            push!(centroids, collect(Float64, d)); labels[i] = length(centroids)
        else
            labels[i] = best
        end
    end
    return labels
end

_medoid(descrs, members) =
    members[argmin([sum(_descr_dist(descrs[m], descrs[o]) for o in members) for m in members])]

# k représentants couvrant les familles timbrales : un médoïde par cluster
# (plus gros d'abord), complété en farthest-first si moins de clusters que k.
function cluster_representatives(pop::Population, cands::Vector{Candidate}, k::Int)
    store = _descr_store(pop)
    have = [c for c in cands if haskey(store, c.id)]
    length(have) <= k && return have
    descrs = [store[c.id] for c in have]
    labels = cluster_descriptors(descrs)
    sizes = [count(==(cl), labels) for cl in 1:maximum(labels)]
    reps = Int[]
    for cl in sortperm(sizes; rev = true)
        push!(reps, _medoid(descrs, [i for i in eachindex(labels) if labels[i] == cl]))
        length(reps) >= k && break
    end
    remaining = setdiff(collect(eachindex(have)), reps)
    while length(reps) < k && !isempty(remaining)
        far = argmax([minimum(_descr_dist(descrs[r], descrs[m]) for r in reps) for m in remaining])
        push!(reps, remaining[far]); deleteat!(remaining, far)
    end
    return Candidate[have[i] for i in reps[1:min(k, length(reps))]]
end

"""
    harvest_topk!(pop, rng; pool_size, k, analyze) -> pop

Un tour « illumination » : génère `pool_size` candidats, les MESURE tous
(via `analyze`, par défaut le rendu NRT), range les descripteurs, puis
n'expose que `k` candidats : **mode A** (rôle actif) = les meilleurs par
role_fit ; **mode B** (pas de rôle) = représentants des familles timbrales
(clustering). `analyze` est injectable (tests : vecteurs simulés).
"""
function harvest_topk!(pop::Population, rng::AbstractRNG;
                       pool_size::Int = 4 * pop.gen_size, k::Int = pop.gen_size,
                       analyze = analyze_genomes)
    _update_hall!(pop)
    pop.generation += 1
    _apply_global_chaos!(pop)
    pool = generate_pool(pop, rng, pool_size)
    descrs = analyze(Genome[c.genome for c in pool])
    store = _descr_store(pop)
    for (c, d) in zip(pool, descrs)
        store[c.id] = collect(Float64, d)
    end
    pop.candidates = get(pop.state, :role, nothing) === nothing ?
        cluster_representatives(pop, pool, k) :   # mode B : explore les familles
        rank_topk(pop, pool, k)                   # mode A : cible le rôle
    return pop
end
