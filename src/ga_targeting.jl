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

"""
    harvest_topk!(pop, rng; pool_size, k, analyze) -> pop

Un tour « illumination » : génère `pool_size` candidats, les MESURE tous
(via `analyze`, par défaut le rendu NRT), range les descripteurs, puis
n'expose que les `k` meilleurs (par role_fit en mode A). `analyze` est
injectable (tests : vecteurs descripteurs simulés ; runtime : NRT sclang).
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
    pop.candidates = rank_topk(pop, pool, k)
    return pop
end
