# src/ga_engine.jl
# Population de candidats + poids (favoriser/dévaluer). select→next_gen
# en mode breeding pool (modèle 2). Les poids vivent à travers les
# générations → brancher le modèle (3) ne changerait que next_generation!.
# Chaque candidat porte un id + une origine ; un registre de lignée
# permet de reconstruire l'ascendance d'un candidat sur commande.
using Random

mutable struct Candidate
    genome::Genome
    weight::Float64        # >0 favori, <0 dévalué, 0 neutre
    id::Int               # identité unique dans la session
    origin::String        # "graine" | "muté #x" | "× #x×#y" | "élite #x"
end
# Compat : construction sans lignée (tests, restauration de session).
Candidate(genome::Genome, weight::Float64) = Candidate(genome, weight, 0, "graine")

# Stratégies de sélection → génération suivante (cf. _nextgen_*).
const GA_STRATEGIES = (:breeding, :champion, :tournament, :weighted, :novelty, :cooling)

mutable struct Population
    candidates::Vector{Candidate}
    base::Genome                 # graine de repli quand aucun favori
    generation::Int
    radius::Float64              # rayon de divergence (mutation)
    gen_size::Int               # nb de candidats par génération
    crossover_prob::Float64     # proba de croisement vs mutation
    elitism::Int                # nb de favoris conservés tels quels
    strategy::Symbol            # ∈ GA_STRATEGIES
    next_cid::Int               # compteur d'id de candidat
    lineage::Dict{Int,NamedTuple}   # id => (gen, origin, parents)
end
# Compat : restauration de session (Task 14) passe 4 args positionnels.
Population(c::Vector{Candidate}, b::Genome, g::Int, r::Float64) =
    Population(c, b, g, r, length(c), 0.5, 1, :breeding,
               maximum((x.id for x in c); init = 0) + 1, Dict{Int,NamedTuple}())

_new_cid!(pop::Population) = (id = pop.next_cid; pop.next_cid += 1; id)
function _record!(pop::Population, id::Int, origin::AbstractString, parents::Vector{Int})
    pop.lineage[id] = (gen = pop.generation, origin = String(origin), parents = parents)
    return id
end

function init_population(base::Genome, n::Int, rng::AbstractRNG;
                         radius::Float64 = 0.5)
    pop = Population(Candidate[], _copy_genome(base), 0, radius, n, 0.5, 1,
                     :breeding, 1, Dict{Int,NamedTuple}())
    for _ in 1:n
        cid = _new_cid!(pop)
        _record!(pop, cid, "graine", Int[])
        push!(pop.candidates,
              Candidate(mutate(base, rng; radius = radius), 0.0, cid, "graine"))
    end
    return pop
end

function _toggle_weight!(pop::Population, i::Int, val::Float64)
    1 <= i <= length(pop.candidates) || return
    c = pop.candidates[i]
    c.weight = (c.weight == val) ? 0.0 : val
    return
end
favor!(pop::Population, i::Int)   = _toggle_weight!(pop, i, 1.0)
devalue!(pop::Population, i::Int) = _toggle_weight!(pop, i, -1.0)

# Crée un candidat en enregistrant sa lignée.
function _spawn!(pop::Population, genome::Genome, origin::AbstractString,
                 parents::Vector{Int})
    cid = _new_cid!(pop)
    _record!(pop, cid, String(origin), parents)
    return Candidate(genome, 0.0, cid, String(origin))
end

function next_generation!(pop::Population, rng::AbstractRNG)
    pop.generation += 1
    s = pop.strategy
    if s === :champion
        _nextgen_champion!(pop, rng)
    elseif s === :tournament
        _nextgen_tournament!(pop, rng)
    elseif s === :weighted
        _nextgen_weighted!(pop, rng)
    elseif s === :novelty
        _nextgen_novelty!(pop, rng)
    elseif s === :cooling
        pop.radius = max(0.05, pop.radius * 0.85)   # refroidissement progressif
        _nextgen_breeding!(pop, rng)
    else
        _nextgen_breeding!(pop, rng)                # :breeding (défaut)
    end
    return pop
end

# 1. Pool de reproduction : élitisme + croisement + mutation des favoris.
function _nextgen_breeding!(pop::Population, rng::AbstractRNG)
    n = pop.gen_size
    favored = sort([c for c in pop.candidates if c.weight > 0]; by = c -> -c.weight)
    parents = isempty(favored) ? [Candidate(pop.base, 0.0)] : favored
    out = Candidate[]
    for e in first(favored, isempty(favored) ? 0 : pop.elitism)
        push!(out, _spawn!(pop, _copy_genome(e.genome), "élite #$(e.id)", [e.id]))
    end
    while length(out) < n
        if length(parents) >= 2 && rand(rng) < pop.crossover_prob
            pa = rand(rng, parents); pb = rand(rng, parents)
            push!(out, _spawn!(pop, crossover(pa.genome, pb.genome, rng),
                               "× #$(pa.id)×#$(pb.id)", [pa.id, pb.id]))
        else
            pa = rand(rng, parents)
            push!(out, _spawn!(pop, mutate(pa.genome, rng; radius = pop.radius),
                               "muté #$(pa.id)", [pa.id]))
        end
    end
    pop.candidates = out[1:n]
end

# 2. Champion & divergence : un seul favori, toute la génération = ses mutations.
function _nextgen_champion!(pop::Population, rng::AbstractRNG)
    n = pop.gen_size
    favored = sort([c for c in pop.candidates if c.weight > 0]; by = c -> -c.weight)
    champ = isempty(favored) ? Candidate(pop.base, 0.0) : favored[1]
    out = Candidate[_spawn!(pop, _copy_genome(champ.genome), "champion #$(champ.id)", [champ.id])]
    while length(out) < n
        push!(out, _spawn!(pop, mutate(champ.genome, rng; radius = pop.radius),
                           "muté #$(champ.id)", [champ.id]))
    end
    pop.candidates = out[1:n]
end

# 3. Tournoi : pour chaque parent on tire k candidats, le mieux noté gagne.
function _tournament_pick(pop::Population, rng::AbstractRNG; k::Int = 3)
    pool = pop.candidates
    isempty(pool) && return Candidate(pop.base, 0.0)
    best = rand(rng, pool)
    for _ in 2:k
        c = rand(rng, pool)
        c.weight > best.weight && (best = c)
    end
    return best
end
function _nextgen_tournament!(pop::Population, rng::AbstractRNG)
    n = pop.gen_size
    out = Candidate[]
    while length(out) < n
        pa = _tournament_pick(pop, rng)
        if rand(rng) < pop.crossover_prob
            pb = _tournament_pick(pop, rng)
            push!(out, _spawn!(pop, crossover(pa.genome, pb.genome, rng),
                               "tournoi #$(pa.id)×#$(pb.id)", [pa.id, pb.id]))
        else
            push!(out, _spawn!(pop, mutate(pa.genome, rng; radius = pop.radius),
                               "tournoi #$(pa.id)", [pa.id]))
        end
    end
    pop.candidates = out[1:n]
end

# 4. Population pondérée (« vrai GA ») : roulette proportionnelle au score
#    (favori haut, neutre médian, dévalué bas mais non nul → diversité).
function _weighted_pick(pop::Population, rng::AbstractRNG)
    pool = pop.candidates
    isempty(pool) && return Candidate(pop.base, 0.0)
    scores = [max(c.weight + 1.0, 0.05) for c in pool]
    r = rand(rng) * sum(scores)
    acc = 0.0
    for (i, sc) in enumerate(scores)
        acc += sc
        acc >= r && return pool[i]
    end
    return pool[end]
end
function _nextgen_weighted!(pop::Population, rng::AbstractRNG)
    n = pop.gen_size
    out = Candidate[]
    while length(out) < n
        pa = _weighted_pick(pop, rng)
        if rand(rng) < pop.crossover_prob
            pb = _weighted_pick(pop, rng)
            push!(out, _spawn!(pop, crossover(pa.genome, pb.genome, rng),
                               "pondéré #$(pa.id)×#$(pb.id)", [pa.id, pb.id]))
        else
            push!(out, _spawn!(pop, mutate(pa.genome, rng; radius = pop.radius),
                               "pondéré #$(pa.id)", [pa.id]))
        end
    end
    pop.candidates = out[1:n]
end

# 5. Recherche de nouveauté : on garde les enfants les plus ÉLOIGNÉS
#    génétiquement de la population (anti-convergence, « surprends-moi »).
function _nextgen_novelty!(pop::Population, rng::AbstractRNG; tries::Int = 4)
    n = pop.gen_size
    pool = [c for c in pop.candidates if c.weight >= 0]
    isempty(pool) && (pool = pop.candidates)
    isempty(pool) && (pool = [Candidate(pop.base, 0.0)])
    ref = [c.genome for c in pop.candidates]
    out = Candidate[]
    while length(out) < n
        best = nothing; best_d = -1.0; best_parent = 0
        for _ in 1:tries
            pa = rand(rng, pool)
            child = mutate(pa.genome, rng; radius = max(pop.radius, 0.6))
            allref = vcat(ref, [c.genome for c in out])
            d = isempty(allref) ? 1.0 :
                minimum(genome_distance(child, gref) for gref in allref)
            if d > best_d
                best_d = d; best = child; best_parent = pa.id
            end
        end
        push!(out, _spawn!(pop, best, "nouveauté #$(best_parent)", [best_parent]))
    end
    pop.candidates = out[1:n]
end

# regénère sans avancer la sélection (bouton R) : re-mute la base.
function reshuffle!(pop::Population, rng::AbstractRNG)
    n = pop.gen_size
    pop.candidates = Candidate[]
    for _ in 1:n
        cid = _new_cid!(pop)
        _record!(pop, cid, "graine", Int[])
        push!(pop.candidates,
              Candidate(mutate(pop.base, rng; radius = pop.radius), 0.0, cid, "graine"))
    end
    return pop
end

"""
    lineage_chain(pop, id; max_depth=8) -> Vector{NamedTuple}

Walk a candidate's ancestry from the lineage registry, newest first.
Each entry is `(id, gen, origin)`. Stops at roots (graines) or when no
parent is recorded (e.g. after a session restore that didn't keep the
full tree).
"""
function lineage_chain(pop::Population, id::Int; max_depth::Int = 8)
    out = NamedTuple[]
    cur = id
    seen = Set{Int}()
    for _ in 1:max_depth
        (cur in seen) && break
        push!(seen, cur)
        entry = get(pop.lineage, cur, nothing)
        if entry === nothing
            push!(out, (id = cur, gen = -1, origin = "?"))
            break
        end
        push!(out, (id = cur, gen = entry.gen, origin = entry.origin))
        isempty(entry.parents) && break
        cur = entry.parents[1]   # principal parent
    end
    return out
end
