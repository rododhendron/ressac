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
const GA_STRATEGIES = (:breeding, :champion, :tournament, :weighted, :novelty,
                       :cooling, :bayesian, :quality_diversity)

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
    state::Dict{Symbol,Any}     # état par-stratégie (archive QD, historique BO)
    energy_target::Float64      # cible d'énergie (ressort de parcimonie)
    stiffness::Float64          # raideur du ressort (faible = oscille/déborde)
end
# Compat : restauration de session (Task 14) passe 4 args positionnels.
Population(c::Vector{Candidate}, b::Genome, g::Int, r::Float64) =
    Population(c, b, g, r, length(c), 0.5, 1, :bayesian,
               maximum((x.id for x in c); init = 0) + 1,
               Dict{Int,NamedTuple}(), Dict{Symbol,Any}(),
               _DEFAULT_ENERGY_TARGET, _DEFAULT_STIFFNESS)

# ── Dérive chaotique de la cible d'énergie ─────────────────────────
# Pour ne JAMAIS se figer sur une complexité (donc sur les mêmes sons),
# la cible d'énergie est promenée par une map logistique (régime
# chaotique, r=3.9) : déterministe mais non-périodique. La cible
# « erre » dans [E* − span, E* + span] au fil des générations. En QD,
# chaque NICHE porte sa propre phase → les familles structurelles se
# stabilisent à des complexités différentes et continuent d'explorer.
_chaos_next(x::Float64) = (y = 3.9 * x * (1.0 - x); (y <= 0.0 || y >= 1.0) ? 0.5 : y)

function _chaos_step!(pop::Population, key::Symbol; init::Float64 = 0.37)
    x = _chaos_next(get(pop.state, key, init)::Float64)
    pop.state[key] = x
    return x
end

_chaos_span(pop::Population) = get(pop.state, :chaos_span, 6.0)::Float64
_chaos_on(pop::Population) = get(pop.state, :chaos_on, true)::Bool
# x∈(0,1) → cible bornée autour du centre réglé par l'utilisateur.
_target_from_phase(pop::Population, x::Float64) =
    max(2.0, pop.energy_target + (x - 0.5) * 2.0 * _chaos_span(pop))

# Cible effective de la génération courante (offset chaotique global posé
# par _apply_global_chaos! ; 0 si chaos coupé).
_current_target(pop::Population) =
    max(2.0, pop.energy_target + get(pop.state, :chaos_offset, 0.0)::Float64)

# Avance la phase chaotique GLOBALE d'un cran (1×/génération).
function _apply_global_chaos!(pop::Population)
    pop.state[:chaos_offset] =
        _chaos_on(pop) ? (_chaos_step!(pop, :chaos_x) - 0.5) * 2.0 * _chaos_span(pop) : 0.0
    return nothing
end

# Mutation pilotée par les réglages d'énergie de la population. `target`
# par défaut = cible effective (avec dérive chaotique) ; les stratégies
# par-niche (QD) passent une cible explicite.
_mutate(pop::Population, g::Genome, rng::AbstractRNG;
        radius::Float64 = pop.radius, target::Float64 = _current_target(pop)) =
    mutate(g, rng; radius = radius, target = target, stiffness = pop.stiffness)

_new_cid!(pop::Population) = (id = pop.next_cid; pop.next_cid += 1; id)
function _record!(pop::Population, id::Int, origin::AbstractString, parents::Vector{Int})
    pop.lineage[id] = (gen = pop.generation, origin = String(origin), parents = parents)
    return id
end

function init_population(base::Genome, n::Int, rng::AbstractRNG;
                         radius::Float64 = 0.5)
    pop = Population(Candidate[], _copy_genome(base), 0, radius, n, 0.5, 1,
                     :bayesian, 1, Dict{Int,NamedTuple}(), Dict{Symbol,Any}(),
                     _DEFAULT_ENERGY_TARGET, _DEFAULT_STIFFNESS)
    for _ in 1:n
        cid = _new_cid!(pop)
        _record!(pop, cid, "graine", Int[])
        push!(pop.candidates,
              Candidate(_mutate(pop, base, rng; radius = radius), 0.0, cid, "graine"))
    end
    return pop
end

# Note GRADUÉE : favoriser/dévaluer incrémente/décrémente le poids (au
# lieu d'un simple oui/non), borné à [-3, +3]. Les stratégies (tournoi,
# pondéré, bayésien) exploitent directement ce poids comme fitness.
const _WEIGHT_MAX = 3.0

function _bump_weight!(pop::Population, i::Int, delta::Float64)
    1 <= i <= length(pop.candidates) || return
    c = pop.candidates[i]
    c.weight = clamp(c.weight + delta, -_WEIGHT_MAX, _WEIGHT_MAX)
    return
end
favor!(pop::Population, i::Int)   = _bump_weight!(pop, i, 1.0)
devalue!(pop::Population, i::Int) = _bump_weight!(pop, i, -1.0)

# Crée un candidat en enregistrant sa lignée.
function _spawn!(pop::Population, genome::Genome, origin::AbstractString,
                 parents::Vector{Int})
    cid = _new_cid!(pop)
    _record!(pop, cid, String(origin), parents)
    return Candidate(genome, 0.0, cid, String(origin))
end

# Archive les génomes favorisés (à travers toute la session) pour
# pouvoir les repêcher quand l'exploration a convergé.
function _update_hall!(pop::Population; cap::Int = 30)
    hall = get!(pop.state, :hall, Genome[])::Vector{Genome}
    for c in pop.candidates
        c.weight > 0 && push!(hall, _copy_genome(c.genome))
    end
    length(hall) > cap && (pop.state[:hall] = hall[(end - cap + 1):end])
    return nothing
end

# Rien noté → on EXPLORE largement : dérive depuis la population courante
# (+ hall + graine) à divergence accrue, au lieu de re-mouler la graine.
# C'est ce qui « re-bruise » quand l'utilisateur skippe la sélection.
function _nextgen_explore!(pop::Population, rng::AbstractRNG)
    pool = Genome[c.genome for c in pop.candidates]
    append!(pool, get(pop.state, :hall, Genome[])::Vector{Genome})
    push!(pool, pop.base)
    r = clamp(max(pop.radius, 0.5) * 1.2, 0.0, 1.0)
    out = Candidate[]
    while length(out) < pop.gen_size
        push!(out, _spawn!(pop, _mutate(pop, rand(rng, pool), rng; radius = r), "exploré", Int[]))
    end
    pop.candidates = out[1:pop.gen_size]
    return pop
end

function next_generation!(pop::Population, rng::AbstractRNG)
    _update_hall!(pop)
    pop.generation += 1
    _apply_global_chaos!(pop)        # promène la cible d'énergie (anti-figement)
    # Aucune note → exploration large (toutes stratégies confondues).
    if all(c -> c.weight == 0.0, pop.candidates)
        return _nextgen_explore!(pop, rng)
    end
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
    elseif s === :bayesian
        _nextgen_bayesian!(pop, rng)
    elseif s === :quality_diversity
        _nextgen_quality_diversity!(pop, rng)
    else
        _nextgen_breeding!(pop, rng)                # :breeding (défaut)
    end
    return pop
end

# Mode TUNE : orbite paramétrique autour d'un son ancré. La structure
# (graphe d'UGens) est GELÉE — seuls les constantes, rates et contrôles
# (freq/sustain/release) bougent. L'ancre est conservée INTACTE en tête
# pour servir de référence audible. C'est le pendant « réglage fin » de
# next_generation! (« rebrasser »). Indépendant de la stratégie : le tri
# par goût ne s'applique pas, on tourne juste autour de l'ancre.
function tune_generation!(pop::Population, anchor::Genome, rng::AbstractRNG)
    _update_hall!(pop)
    pop.generation += 1
    r = max(0.05, pop.radius)
    out = Candidate[_spawn!(pop, _copy_genome(anchor), "ancre", Int[])]
    while length(out) < pop.gen_size
        child = mutate(anchor, rng; radius = r, structural = false, control_floor = 0.0)
        push!(out, _spawn!(pop, child, "tuné", Int[]))
    end
    pop.candidates = out[1:pop.gen_size]
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
            push!(out, _spawn!(pop, _mutate(pop, pa.genome, rng),
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
        push!(out, _spawn!(pop, _mutate(pop, champ.genome, rng),
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
            push!(out, _spawn!(pop, _mutate(pop, pa.genome, rng),
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
            push!(out, _spawn!(pop, _mutate(pop, pa.genome, rng),
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
            child = _mutate(pop, pa.genome, rng; radius = max(pop.radius, 0.6))
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

# Skip de la sélection (bouton R) : RE-DIVERGE pour échapper à la
# convergence. Repêche de VIEUX parents (hall of fame des favoris de la
# session) + les candidats courants + la graine, et mute fort (rayon
# boosté). Idéal quand un surrogate/une stratégie a convergé et qu'on
# veut réinjecter de la nouveauté sans repartir de zéro.
function diverge!(pop::Population, rng::AbstractRNG)
    _update_hall!(pop)
    pool = Genome[c.genome for c in pop.candidates]
    append!(pool, get(pop.state, :hall, Genome[])::Vector{Genome})
    push!(pool, pop.base)
    r = clamp(max(pop.radius, 0.6) * 1.3, 0.0, 1.0)   # divergence boostée
    pop.generation += 1
    out = Candidate[]
    while length(out) < pop.gen_size
        g = rand(rng, pool)
        push!(out, _spawn!(pop, _mutate(pop, g, rng; radius = r), "divergé", Int[]))
    end
    pop.candidates = out[1:pop.gen_size]
    return pop
end

# Ancien nom conservé : re-mute simplement la base.
function reshuffle!(pop::Population, rng::AbstractRNG)
    n = pop.gen_size
    pop.candidates = Candidate[]
    for _ in 1:n
        cid = _new_cid!(pop)
        _record!(pop, cid, "graine", Int[])
        push!(pop.candidates,
              Candidate(_mutate(pop, pop.base, rng), 0.0, cid, "graine"))
    end
    return pop
end

# 7. Bayésien (surrogate de préférences) : un modèle linéaire léger du
#    goût (appris sur tes notes) pré-score un GRAND pool interne d'enfants ;
#    on garde les mieux notés (exploitation) + quelques-uns lointains
#    (exploration). C'est la version data-efficient, sans GP, de la BO
#    par préférences — l'humain ne note que la poignée affichée.
function _bo_taste(hist::Vector{Tuple{Vector{Float64},Float64}})
    isempty(hist) && return nothing
    dim = length(hist[1][1])
    taste = zeros(Float64, dim)
    wsum = 0.0
    for (f, w) in hist
        length(f) == dim || continue
        taste .+= w .* f
        wsum += abs(w)
    end
    wsum < 1e-9 && return nothing
    return taste ./ wsum
end

_featdist(a::Vector{Float64}, b::Vector{Float64}) = sqrt(sum((a .- b) .^ 2))
function _minmax_norm(xs::Vector{Float64})
    lo, hi = extrema(xs)
    hi - lo < 1e-9 && return fill(0.5, length(xs))
    return (xs .- lo) ./ (hi - lo)
end

function _nextgen_bayesian!(pop::Population, rng::AbstractRNG)
    n = pop.gen_size
    hist = get!(pop.state, :bo_examples,
                Vector{Tuple{Vector{Float64},Float64}}())::Vector{Tuple{Vector{Float64},Float64}}
    for c in pop.candidates
        c.weight == 0.0 && continue
        push!(hist, (genome_feature_vec(c.genome), c.weight))
    end
    taste = _bo_taste(hist)
    favored = [c for c in pop.candidates if c.weight > 0]
    parents = isempty(favored) ? pop.candidates : favored
    isempty(parents) && (parents = [Candidate(pop.base, 0.0)])
    pool = Candidate[]
    for _ in 1:(n * 5)
        pa = rand(rng, parents)
        child = (length(parents) >= 2 && rand(rng) < pop.crossover_prob) ?
            crossover(pa.genome, rand(rng, parents).genome, rng) :
            _mutate(pop, pa.genome, rng)
        push!(pool, _spawn!(pop, child, "surrogate #$(pa.id)", [pa.id]))
    end
    if taste === nothing
        pop.candidates = pool[1:n]
        return
    end
    # Active inference (lite) : acquisition = valeur PRAGMATIQUE (goût
    # prédit, exploitation) + β · valeur ÉPISTÉMIQUE (incertitude ≈
    # éloignement des exemples déjà notés → ta note y réduit le plus
    # l'incertitude). Les deux normalisés sur le pool pour être
    # comparables.
    rated = [f for (f, _) in hist]
    feats = [genome_feature_vec(c.genome) for c in pool]
    exploit = _minmax_norm([sum(f .* taste) for f in feats])
    uncert = _minmax_norm([isempty(rated) ? 0.0 : minimum(_featdist(f, rf) for rf in rated)
                           for f in feats])
    β = 0.45
    acq = (1 - β) .* exploit .+ β .* uncert
    order = sortperm(acq; rev = true)
    pop.candidates = pool[order[1:n]]
end

# 8. Quality-Diversity (MAP-Elites) : archive par RESSEMBLANCE DE
#    STRUCTURE. Chaque niche = une famille structurelle (un candidat
#    rejoint la niche du plus proche par genome_distance si sous le
#    seuil, sinon il ouvre une nouvelle niche). On reproduit depuis ces
#    élites diverses → couvre l'espace sonore sans perdre de famille.
const _QD_NICHE_THRESHOLD = 1.5

function _qd_update_archive!(archive::Vector{Candidate}, cands)
    for c in cands
        best_i = 0; best_d = Inf
        for (i, e) in enumerate(archive)
            d = genome_distance(c.genome, e.genome)
            d < best_d && (best_d = d; best_i = i)
        end
        if best_i == 0 || best_d > _QD_NICHE_THRESHOLD
            push!(archive, c)                       # nouvelle famille structurelle
        elseif c.weight > archive[best_i].weight
            archive[best_i] = c                     # meilleur de sa famille
        end
    end
    return archive
end

# Cible d'énergie PROPRE à une niche : chaque famille structurelle porte sa
# phase chaotique → des complexités différentes par niche, qui errent.
function _qd_niche_target!(pop::Population, niche::Int)
    _chaos_on(pop) || return _current_target(pop)
    phases = get!(pop.state, :qd_chaos, Dict{Int,Float64}())::Dict{Int,Float64}
    x = _chaos_next(get(phases, niche, mod(0.13 + 0.27 * niche, 1.0)))   # graine variée/niche
    phases[niche] = x
    return _target_from_phase(pop, x)
end

function _nextgen_quality_diversity!(pop::Population, rng::AbstractRNG)
    n = pop.gen_size
    archive = get!(pop.state, :qd_archive, Candidate[])::Vector{Candidate}
    _qd_update_archive!(archive, pop.candidates)
    elites = isempty(archive) ? pop.candidates : archive
    isempty(elites) && (elites = [Candidate(pop.base, 0.0)])
    out = Candidate[]
    while length(out) < n
        ni = rand(rng, 1:length(elites))
        e = elites[ni]
        t = _qd_niche_target!(pop, ni)        # attracteur chaotique par niche
        push!(out, _spawn!(pop, _mutate(pop, e.genome, rng; target = t),
                           "QD #$(e.id)", [e.id]))
    end
    pop.candidates = out[1:n]
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
