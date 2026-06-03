# src/genome_moves.jl
# Bibliothèque de « bons coups » — des transformations structurelles
# MUSICALEMENT sensées qu'on peut greffer sur un génome : ajouter un
# filtre résonant, une saturation, une reverb, une couche détunée, un
# trémolo, une sous-octave… Utilisables (a) à la main sur le candidat
# focalisé, (b) comme biais de mutation quand la GUIDANCE est activée.
#
# Guidance OPTIONNELLE + configurable : registre `GOOD_MOVES` (coups
# ponctuels) et `GUIDANCE_DIRS` (pousse vers une notion perceptive).

# Enveloppe la sortie courante dans un nouvel UGen (la sortie devient sa
# première entrée signal ; les autres slots = défauts du catalogue).
function _wrap_output!(g::Genome, ugen::Symbol)
    spec = ugen_spec(ugen)
    spec === nothing && return g
    args = Arg[]
    for (i, sp) in enumerate(spec.slots)
        push!(args, i == 1 ? NodeRef(g.output_id) : ConstArg(sp.default))
    end
    g.output_id = add_node!(g, ugen, spec.rates[1], args)
    return g
end

# ── Les coups ──────────────────────────────────────────────────────
function move_add_filter!(g::Genome, rng::AbstractRNG)
    _wrap_output!(g, rand(rng, (:RLPF, :Resonz, :MoogFF, :LPF, :BPF)))
end

function move_add_saturation!(g::Genome, rng::AbstractRNG)
    _wrap_output!(g, rand(rng, (:Tanh, :Fold2, :Clip2)))
end

function move_add_reverb!(g::Genome, rng::AbstractRNG)
    g.output_id = add_node!(g, :FreeVerb, :ar,
        Arg[NodeRef(g.output_id), ConstArg(0.4), ConstArg(0.6), ConstArg(0.5)])
    return g
end

function move_detune_layer!(g::Genome, rng::AbstractRNG)
    op_duplicate_subgraph!(g, rng)   # clone un groupe + mixe en parallèle
    return g
end

function move_add_tremolo!(g::Genome, rng::AbstractRNG)
    lfo = add_node!(g, :SinOscKR, :kr, Arg[ConstArg(rand(rng, (2.0, 4.0, 6.0, 8.0)))])
    # MulAdd(in, mul, add) = in*mul + add ; mul = LFO → trémolo
    g.output_id = add_node!(g, :MulAdd, :ar,
        Arg[NodeRef(g.output_id), NodeRef(lfo), ConstArg(0.0)])
    return g
end

function move_sub_octave!(g::Genome, rng::AbstractRNG)
    sub = add_node!(g, :SinOsc, :ar,
        Arg[ConstArg(rand(rng, (55.0, 82.5, 110.0))), ConstArg(0.0)])
    g.output_id = add_node!(g, :Mix, :ar, Arg[NodeRef(g.output_id), NodeRef(sub)])
    return g
end

const GOOD_MOVES = Dict{Symbol,Function}(
    :filtre      => move_add_filter!,
    :saturation  => move_add_saturation!,
    :reverb      => move_add_reverb!,
    :detune      => move_detune_layer!,
    :tremolo     => move_add_tremolo!,
    :sous_octave => move_sub_octave!,
)
const _GOOD_MOVE_FNS = collect(values(GOOD_MOVES))

"""
    apply_good_move!(g, rng; move=nothing) -> Genome

Greffe un « bon coup » (aléatoire ou nommé) sur `g`, puis normalise.
"""
function apply_good_move!(g::Genome, rng::AbstractRNG; move::Union{Symbol,Nothing} = nothing)
    fn = move === nothing ? rand(rng, _GOOD_MOVE_FNS) :
         get(GOOD_MOVES, move, rand(rng, _GOOD_MOVE_FNS))
    fn(g, rng)
    repair!(g)
    repair_audible!(g)
    repair!(g)
    return g
end

# ── Guidance DIRECTIONNELLE : pousser vers une notion perceptive ────
# Petites transformations appliquées à chaque candidat d'une génération
# quand une direction est active → la population dérive vers la notion
# (plus grave, moins saturé, …) tout en évoluant par tes notes.

# Multiplie le cutoff d'un filtre (constante du slot :freq) ; true si fait.
function _nudge_cutoff!(g::Genome, factor::Float64)
    for (id, n) in g.nodes
        spec = ugen_spec(n.ugen)
        (spec === nothing || spec.role !== :filter) && continue
        for (i, sp) in enumerate(spec.slots)
            (sp.name === :freq && i <= length(n.args) && n.args[i] isa ConstArg) || continue
            n.args[i] = ConstArg(clamp(n.args[i].value * factor, sp.lo, sp.hi))
            return true
        end
    end
    return false
end

# Bypass un nœud de mise en forme (saturation/shaper) s'il y en a un.
function _remove_a_shaper!(g::Genome)
    for (id, n) in g.nodes
        n.ugen in (:Tanh, :Fold2, :Clip2) || continue
        length(g.nodes) <= 1 && return false
        bypass = ConstArg(0.0)
        for a in n.args
            a isa NodeRef && (bypass = a; break)
        end
        delete!(g.nodes, id)
        for other in values(g.nodes), j in eachindex(other.args)
            other.args[j] isa NodeRef && other.args[j].id == id && (other.args[j] = bypass)
        end
        g.output_id == id && (g.output_id = bypass isa NodeRef ? bypass.id : 0)
        return true
    end
    return false
end

dir_grave!(g, rng)    = (g.controls[:freq] = clamp(control(g, :freq) * 0.8, 40.0, 4000.0); g)
dir_aigu!(g, rng)     = (g.controls[:freq] = clamp(control(g, :freq) * 1.25, 40.0, 4000.0); g)
dir_sombre!(g, rng)   = (_nudge_cutoff!(g, 0.7) || _wrap_output!(g, :LPF); g)
dir_brillant!(g, rng) = (_nudge_cutoff!(g, 1.4) || _wrap_output!(g, :HPF); g)
dir_sature!(g, rng)   = move_add_saturation!(g, rng)
dir_clair!(g, rng)    = (_remove_a_shaper!(g); g)

const GUIDANCE_DIRS = Dict{Symbol,Function}(
    :grave => dir_grave!, :aigu => dir_aigu!,
    :sombre => dir_sombre!, :brillant => dir_brillant!,
    :sature => dir_sature!, :clair => dir_clair!,
)
# Ordre de défilement (avec :none au début pour désactiver).
const GUIDANCE_ORDER = (:none, :grave, :aigu, :sombre, :brillant, :sature, :clair)

"""
    apply_guidance!(g, dir, rng) -> Genome

Pousse `g` vers la notion `dir` (∈ GUIDANCE_ORDER), puis normalise.
`:none` = no-op.
"""
function apply_guidance!(g::Genome, dir::Symbol, rng::AbstractRNG)
    dir === :none && return g
    fn = get(GUIDANCE_DIRS, dir, nothing)
    fn === nothing && return g
    fn(g, rng)
    repair!(g)
    repair_audible!(g)
    repair!(g)
    return g
end
