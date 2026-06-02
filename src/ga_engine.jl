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

mutable struct Population
    candidates::Vector{Candidate}
    base::Genome                 # graine de repli quand aucun favori
    generation::Int
    radius::Float64              # rayon de divergence (mutation)
    gen_size::Int               # nb de candidats par génération
    crossover_prob::Float64     # proba de croisement vs mutation
    elitism::Int                # nb de favoris conservés tels quels
    next_cid::Int               # compteur d'id de candidat
    lineage::Dict{Int,NamedTuple}   # id => (gen, origin, parents)
end
# Compat : restauration de session (Task 14) passe 4 args positionnels.
Population(c::Vector{Candidate}, b::Genome, g::Int, r::Float64) =
    Population(c, b, g, r, length(c), 0.5, 1,
               maximum((x.id for x in c); init = 0) + 1, Dict{Int,NamedTuple}())

_new_cid!(pop::Population) = (id = pop.next_cid; pop.next_cid += 1; id)
function _record!(pop::Population, id::Int, origin::AbstractString, parents::Vector{Int})
    pop.lineage[id] = (gen = pop.generation, origin = String(origin), parents = parents)
    return id
end

function init_population(base::Genome, n::Int, rng::AbstractRNG;
                         radius::Float64 = 0.5)
    pop = Population(Candidate[], _copy_genome(base), 0, radius, n, 0.5, 1, 1,
                     Dict{Int,NamedTuple}())
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

function next_generation!(pop::Population, rng::AbstractRNG)
    n = pop.gen_size
    favored = [c for c in pop.candidates if c.weight > 0]
    sort!(favored; by = c -> -c.weight)
    parents = isempty(favored) ? [Candidate(pop.base, 0.0)] : favored
    pop.generation += 1
    out = Candidate[]
    # élitisme : les meilleurs favoris passent tels quels (nouvel id).
    for e in first(favored, isempty(favored) ? 0 : pop.elitism)
        cid = _new_cid!(pop)
        org = "élite #$(e.id)"
        _record!(pop, cid, org, [e.id])
        push!(out, Candidate(_copy_genome(e.genome), 0.0, cid, org))
    end
    while length(out) < n
        if length(parents) >= 2 && rand(rng) < pop.crossover_prob
            pa = rand(rng, parents); pb = rand(rng, parents)
            child = crossover(pa.genome, pb.genome, rng)
            cid = _new_cid!(pop)
            org = "× #$(pa.id)×#$(pb.id)"
            _record!(pop, cid, org, [pa.id, pb.id])
            push!(out, Candidate(child, 0.0, cid, org))
        else
            pa = rand(rng, parents)
            child = mutate(pa.genome, rng; radius = pop.radius)
            cid = _new_cid!(pop)
            org = "muté #$(pa.id)"
            _record!(pop, cid, org, [pa.id])
            push!(out, Candidate(child, 0.0, cid, org))
        end
    end
    pop.candidates = out[1:n]
    return pop
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
