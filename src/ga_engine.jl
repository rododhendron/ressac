# src/ga_engine.jl
# Population de candidats + poids (favoriser/dévaluer). select→next_gen
# en mode breeding pool (modèle 2). Les poids vivent à travers les
# générations → brancher le modèle (3) ne changerait que next_generation!.
using Random

mutable struct Candidate
    genome::Genome
    weight::Float64        # >0 favori, <0 dévalué, 0 neutre
end

mutable struct Population
    candidates::Vector{Candidate}
    base::Genome           # graine de repli quand aucun favori
    generation::Int
    radius::Float64
end

function init_population(base::Genome, n::Int, rng::AbstractRNG;
                         radius::Float64 = 0.5)
    cands = [Candidate(mutate(base, rng; radius = radius), 0.0) for _ in 1:n]
    return Population(cands, _copy_genome(base), 0, radius)
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
    n = length(pop.candidates)
    favored = [c for c in pop.candidates if c.weight > 0]
    sort!(favored; by = c -> -c.weight)
    parents = isempty(favored) ? [Candidate(pop.base, 0.0)] : favored
    out = Candidate[]
    # élitisme : 1 favori conservé tel quel (si présent)
    isempty(favored) || push!(out, Candidate(_copy_genome(favored[1].genome), 0.0))
    while length(out) < n
        if length(parents) >= 2 && rand(rng) < 0.5
            a = rand(rng, parents).genome
            b = rand(rng, parents).genome
            child = crossover(a, b, rng)
        else
            child = mutate(rand(rng, parents).genome, rng; radius = pop.radius)
        end
        push!(out, Candidate(child, 0.0))
    end
    pop.candidates = out[1:n]
    pop.generation += 1
    return pop
end

# regénère sans avancer la sélection (bouton R) : re-mute la base.
function reshuffle!(pop::Population, rng::AbstractRNG)
    n = length(pop.candidates)
    pop.candidates = [Candidate(mutate(pop.base, rng; radius = pop.radius), 0.0)
                      for _ in 1:n]
    return pop
end
