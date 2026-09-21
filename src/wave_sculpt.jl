# src/wave_sculpt.jl
# Sculpt de l'onde — logique PURE (aucun TUI, aucun SC).
# Un « knob » = un nombre réglable du génome : un ConstArg d'un nœud, ou
# un control global. La disposition suit le flux du signal (épine stable) ;
# le groupement « quartiers mous » émerge de la proximité graphe × acoustique.
# Cf. docs/journal/20260612_waveform_sculpt_design.md.

# ── Modèle de knob ─────────────────────────────────────────────────
struct Knob
    kind::Symbol        # :control | :node
    node_id::Int        # :node → id du nœud ; :control → 0
    arg_index::Int      # :node → position dans node.args ; :control → 0
    name::Symbol        # nom du slot (:freq) ou du control (:freq)
    lo::Float64
    hi::Float64
    logscale::Bool      # balayage multiplicatif quand true
end

# Ranges explicites des controls globaux (pas de SlotSpec) : (lo, hi, log).
const _CONTROL_RANGES = Dict{Symbol,Tuple{Float64,Float64,Bool}}(
    :freq    => (20.0, 8000.0, true),
    :sustain => (0.01, 6.0, false),
    :gain    => (0.0, 1.0, false),
    :release => (0.01, 4.0, false),
)

const _KNOB_STEPS = 40   # nb de crans sur toute l'étendue d'un knob

# Un slot dont le nom évoque une fréquence → balayage logarithmique.
_is_logscale(name::Symbol) = occursin("freq", lowercase(String(name))) ||
                             occursin("cutoff", lowercase(String(name)))

# Énumère tous les knobs : globaux d'abord (CONTROL_EDIT_ORDER), puis les
# ConstArgs ordonnés par flux du signal (_topo_order = sources→sortie).
function enumerate_knobs(g::Genome)
    ks = Knob[]
    for name in CONTROL_EDIT_ORDER
        (lo, hi, log) = get(_CONTROL_RANGES, name, (0.0, 1.0, false))
        push!(ks, Knob(:control, 0, 0, name, lo, hi, log))
    end
    order = _topo_order(g)
    pos = Dict(id => i for (i, id) in enumerate(order))
    consts = _const_slots(g)                 # (node_id, arg_index)
    # tri : par position dans l'épine, puis par index d'argument
    sort!(consts; by = ((nid, i),) -> (get(pos, nid, typemax(Int)), i))
    for (nid, i) in consts
        n = g.nodes[nid]
        spec = ugen_spec(n.ugen)
        if spec !== nothing && i <= length(spec.slots)
            sp = spec.slots[i]
            push!(ks, Knob(:node, nid, i, sp.name, sp.lo, sp.hi, _is_logscale(sp.name)))
        else
            # arité transitoire / slot inconnu → balayage log relatif autour
            # de la valeur courante (jamais d'indexation hors-bornes).
            cur = n.args[i].value
            mag = abs(cur) < 1e-9 ? 1.0 : abs(cur)
            push!(ks, Knob(:node, nid, i, :param, cur - 4mag, cur + 4mag, true))
        end
    end
    return ks
end

knob_value(g::Genome, kb::Knob) =
    kb.kind === :control ? control(g, kb.name) : g.nodes[kb.node_id].args[kb.arg_index].value

function set_knob!(g::Genome, kb::Knob, v::Float64)
    if kb.kind === :control
        g.controls[kb.name] = v
    else
        g.nodes[kb.node_id].args[kb.arg_index] = ConstArg(v)
    end
    return g
end

# Bornes absolues de bon sens (on autorise l'overflow hors plage catalogue).
const _KNOB_LOG_FLOOR = 1.0e-4
const _KNOB_LOG_CEIL  = 2.0e4
const _KNOB_LIN_BOUND = 1.0e6

# Tire le knob de `steps` crans (± entiers). Log = **pas multiplicatif fixe**
# (1/24 d'octave par cran), indépendant de la portée → on peut DÉPASSER la
# plage nominale du catalogue (overflow autorisé, comme le ressort d'énergie).
# Linéaire = pas = fraction de la portée nominale. Clamp uniquement à des
# bornes absolues larges — jamais à la valeur courante.
function knob_tug(kb::Knob, cur::Float64, steps::Int)
    if kb.logscale && cur > 0
        return clamp(cur * 2.0^(steps / 24), _KNOB_LOG_FLOOR, _KNOB_LOG_CEIL)
    end
    unit = (kb.hi > kb.lo ? kb.hi - kb.lo : max(abs(cur), 1.0)) / _KNOB_STEPS
    return clamp(cur + steps * unit, -_KNOB_LIN_BOUND, _KNOB_LIN_BOUND)
end

# Pose une valeur EXACTE (saisie manuelle), bornée seulement par le bon sens.
knob_set_value(kb::Knob, v::Float64) =
    kb.logscale ? clamp(v, _KNOB_LOG_FLOOR, _KNOB_LOG_CEIL) :
                  clamp(v, -_KNOB_LIN_BOUND, _KNOB_LIN_BOUND)

# ── Groupe fonctionnel d'un knob (pour l'affichage groupé en sculpt) ──
# Dérivé du rôle de l'UGen porteur (source/filtre/…) ; les controls
# globaux forment leur propre groupe.
const _ROLE_LABELS = Dict{Symbol,String}(
    :source => "source", :filter => "filtre", :math => "mix",
    :env => "enveloppe", :mod => "modulation")

function knob_group(g::Genome, kb::Knob)
    kb.kind === :control && return "global"
    spec = ugen_spec(g.nodes[kb.node_id].ugen)
    spec === nothing && return "autre"
    return get(_ROLE_LABELS, spec.role, String(spec.role))
end

# Indices des knobs regroupés par fonction, dans l'ordre de l'épine.
# Renvoie un Vector{Tuple{String,Vector{Int}}} (groupe → indices de knobs).
function knob_groups(g::Genome, knobs::Vector{Knob})
    order = String[]; buckets = Dict{String,Vector{Int}}()
    for (i, kb) in enumerate(knobs)
        gl = knob_group(g, kb)
        haskey(buckets, gl) || (push!(order, gl); buckets[gl] = Int[])
        push!(buckets[gl], i)
    end
    return [(gl, buckets[gl]) for gl in order]
end

# ── Édition structurelle : interface de dispatch (les « bricks ») ──
# Chaque brick = une méthode de `structural_edit!` sur un `Val{:op}`. Elle
# mute le graphe, appelle `repair!`, et renvoie le **node_id à refocaliser**
# (ou `nothing` si l'édit n'a rien fait). L'appelant ré-énumère les knobs
# ensuite (le set a changé). Ajouter un brick = ajouter UNE méthode ici.
structural_edit!(g::Genome, op::Symbol, node_id::Int; kwargs...) =
    structural_edit!(g, Val(op), node_id; kwargs...)

# brick 1 — swap : UGen suivant/précédent de même rôle (cyclique).
function structural_edit!(g::Genome, ::Val{:swap_ugen}, node_id::Int; dir::Int = 1)
    swap_node_ugen!(g, node_id; dir = dir) === nothing && return nothing
    return node_id
end

# brick 2 — insert : enveloppe la sortie du nœud focalisé dans un nouvel
# UGen (filtre par défaut). Renvoie l'id du NOUVEAU nœud (à refocaliser).
structural_edit!(g::Genome, ::Val{:insert_after}, node_id::Int; role::Symbol = :filter) =
    insert_node_after!(g, node_id; role = role)

# brick 3 — delete : retire le nœud focalisé en bypassant son signal.
structural_edit!(g::Genome, ::Val{:delete}, node_id::Int; dir::Int = 1) =
    delete_node!(g, node_id)

# brick 4 — rewire : recâble l'entrée audio du nœud vers un autre nœud (cyclique).
structural_edit!(g::Genome, ::Val{:rewire}, node_id::Int; dir::Int = 1) =
    rewire_input!(g, node_id; dir = dir)

# brick 5 — rate : cycle le taux (ar/kr…) du nœud.
structural_edit!(g::Genome, ::Val{:rate}, node_id::Int; dir::Int = 1) =
    toggle_rate!(g, node_id; dir = dir)

# brick 6 — duplicate : clone le sous-graphe du nœud, mixé en parallèle.
structural_edit!(g::Genome, ::Val{:duplicate}, node_id::Int; dir::Int = 1) =
    duplicate_subgraph_at!(g, node_id)

# brick 7 — graft_mod : remplace le slot focalisé (ConstArg) par un LFO.
structural_edit!(g::Genome, ::Val{:graft_mod}, node_id::Int; arg_index::Int = 0) =
    graft_mod!(g, node_id; arg_index = arg_index)

# Remplace l'UGen d'un nœud par le suivant (dir) de MÊME RÔLE, ordre stable
# (par nom). repair! recolle l'arité ; on garde un rate valide. Renvoie le
# nouveau symbole, ou nothing (nœud absent / pas d'alternative).
function swap_node_ugen!(g::Genome, node_id::Int; dir::Int = 1)
    haskey(g.nodes, node_id) || return nothing
    n = g.nodes[node_id]
    spec = ugen_spec(n.ugen)
    spec === nothing && return nothing
    cands = sort!([s.name for s in catalog_by_role(spec.role)])
    length(cands) <= 1 && return nothing
    i = something(findfirst(==(n.ugen), cands), 1)
    nxt = cands[mod1(i + dir, length(cands))]
    nxt === n.ugen && return nothing
    nspec = ugen_spec(nxt)
    n.ugen = nxt
    n.rate in nspec.rates || (n.rate = nspec.rates[1])
    repair!(g)
    return nxt
end

# Enveloppe la SORTIE du nœud `node_id` dans un nouveau nœud de rôle `role` :
# tout ce qui référençait node_id pointe désormais vers le nouveau nœud, dont
# la 1re entrée signal = node_id. Choisit le 1er UGen du rôle (ordre stable) —
# l'utilisateur affine ensuite avec o/O. Renvoie l'id du nouveau nœud (ou nothing).
function insert_node_after!(g::Genome, node_id::Int; role::Symbol = :filter)
    haskey(g.nodes, node_id) || return nothing
    cands = sort!([s.name for s in catalog_by_role(role)])
    isempty(cands) && return nothing
    spec = ugen_spec(first(cands))
    spec === nothing && return nothing
    args = Arg[]
    for (i, sp) in enumerate(spec.slots)
        push!(args, (i == 1 && _is_signalish(sp.kind)) ? NodeRef(node_id) : ConstArg(sp.default))
    end
    new_id = add_node!(g, spec.name, spec.rates[1], args)
    for (id, n) in g.nodes
        id == new_id && continue
        for j in eachindex(n.args)
            a = n.args[j]
            a isa NodeRef && a.id == node_id && (n.args[j] = NodeRef(new_id))
        end
    end
    g.output_id == node_id && (g.output_id = new_id)
    repair!(g)
    return new_id
end

# Position de l'UGen d'un nœud dans le cycle de son rôle : (nom, i, total).
# Sert au feedback « ‹RLPF 2/5› » quand un knob-nœud est focalisé.
function ugen_role_position(g::Genome, node_id::Int)
    haskey(g.nodes, node_id) || return (nothing, 0, 0)
    n = g.nodes[node_id]; spec = ugen_spec(n.ugen)
    spec === nothing && return (n.ugen, 0, 0)
    cands = sort!([s.name for s in catalog_by_role(spec.role)])
    return (n.ugen, something(findfirst(==(n.ugen), cands), 0), length(cands))
end

# La 1re VRAIE entrée audio (`kind === :audio`) d'un nœud, ou nothing. On
# exclut les slots `:signal` (freq modulable d'une source…) : bypasser/recâbler
# à travers eux n'a pas de sens (une source pure n'a pas d'entrée audio).
function _audio_input_slot(n::UGenNode)
    spec = ugen_spec(n.ugen)
    spec === nothing && return nothing
    return findfirst(i -> i <= length(n.args) && spec.slots[i].kind === :audio,
                     1:length(spec.slots))
end

# brick 3 — Retire `node_id` en faisant PASSER son signal d'entrée à sa place :
# tout ce qui le référençait pointe vers son entrée audio (bypass). Refuse une
# source pure (pas de bypass → silence : utiliser swap). Renvoie le nœud sur
# lequel refocaliser (l'entrée reconnectée / la sortie), ou nothing.
function delete_node!(g::Genome, node_id::Int)
    (haskey(g.nodes, node_id) && length(g.nodes) > 1) || return nothing
    n = g.nodes[node_id]
    si = _audio_input_slot(n)
    si === nothing && return nothing            # source pure → pas de contournement
    bypass = n.args[si]
    delete!(g.nodes, node_id)
    for other in values(g.nodes), j in eachindex(other.args)
        other.args[j] isa NodeRef && other.args[j].id == node_id &&
            (other.args[j] = bypass)
    end
    g.output_id == node_id && (g.output_id = bypass isa NodeRef ? bypass.id : 0)
    repair!(g)
    return bypass isa NodeRef ? bypass.id : g.output_id
end

# brick 4 — Recâble l'entrée audio de `node_id` vers le nœud suivant/précédent
# (ordre stable par id, cyclique). repair! casse un éventuel cycle. Renvoie
# node_id (on reste sur le même nœud), ou nothing.
function rewire_input!(g::Genome, node_id::Int; dir::Int = 1)
    haskey(g.nodes, node_id) || return nothing
    n = g.nodes[node_id]
    si = _audio_input_slot(n)
    si === nothing && return nothing
    cands = sort!([id for id in keys(g.nodes) if id != node_id])
    isempty(cands) && return nothing
    cur = n.args[si]
    curid = cur isa NodeRef ? cur.id : 0
    i = something(findfirst(==(curid), cands), 0)
    n.args[si] = NodeRef(cands[mod1(i + dir, length(cands))])
    repair!(g)
    return node_id
end

# brick 5 — Cycle le taux de `node_id` parmi ceux qu'autorise son UGen
# (ar/kr…). repair! propage un éventuel désaccord. Renvoie node_id ou nothing.
function toggle_rate!(g::Genome, node_id::Int; dir::Int = 1)
    haskey(g.nodes, node_id) || return nothing
    n = g.nodes[node_id]
    spec = ugen_spec(n.ugen)
    (spec === nothing || length(spec.rates) <= 1) && return nothing
    i = something(findfirst(==(n.rate), spec.rates), 1)
    n.rate = spec.rates[mod1(i + dir, length(spec.rates))]
    repair!(g)
    return node_id
end

# brick 6 — Clone le sous-graphe enraciné sur `node_id` et le mixe EN PARALLÈLE
# partout où le nœud était consommé (épaississement / détune). Borné à 30 nœuds.
# Renvoie la racine du clone (à refocaliser), ou nothing.
function duplicate_subgraph_at!(g::Genome, node_id::Int)
    (haskey(g.nodes, node_id) && length(g.nodes) < 30) || return nothing
    is_output = g.output_id == node_id
    # consommateurs de node_id — calculés AVANT de cloner (ids d'origine).
    consumers = Tuple{Int,Int}[]
    for (id, n) in g.nodes, j in eachindex(n.args)
        a = n.args[j]
        a isa NodeRef && a.id == node_id && push!(consumers, (id, j))
    end
    (is_output || !isempty(consumers)) || return nothing   # clone orphelin → on ne touche à rien
    sub = collect(_subtree_ids(g, node_id))
    remap = Dict{Int,Int}()
    for old in sub
        remap[old] = g.next_id; g.next_id += 1
    end
    for old in sub
        dn = g.nodes[old]
        newargs = Arg[a isa NodeRef && haskey(remap, a.id) ? NodeRef(remap[a.id]) : a
                      for a in dn.args]
        g.nodes[remap[old]] = UGenNode(remap[old], dn.ugen, dn.rate, newargs)
    end
    clone_root = remap[node_id]
    for (id, j) in consumers                    # mixe le clone en parallèle
        mixid = add_node!(g, :Mix, :ar, Arg[NodeRef(node_id), NodeRef(clone_root)])
        g.nodes[id].args[j] = NodeRef(mixid)
    end
    is_output &&
        (g.output_id = add_node!(g, :Mix, :ar, Arg[NodeRef(node_id), NodeRef(clone_root)]))
    repair!(g)
    return clone_root
end

# brick 7 — Remplace le slot `arg_index` (un ConstArg) de `node_id` par un
# modulateur LFO (rôle :mod, 1er du catalogue). Renvoie l'id du modulateur
# (à refocaliser : on règle ensuite son taux), ou nothing.
function graft_mod!(g::Genome, node_id::Int; arg_index::Int = 0)
    haskey(g.nodes, node_id) || return nothing
    n = g.nodes[node_id]
    (1 <= arg_index <= length(n.args) && n.args[arg_index] isa ConstArg) || return nothing
    mods = catalog_by_role(:mod)
    isempty(mods) && return nothing
    spec = ugen_spec(first(sort!([s.name for s in mods])))
    spec === nothing && return nothing
    mod_id = _new_node_from_spec!(g, spec, ConstArg(spec.slots[1].default))
    g.nodes[node_id].args[arg_index] = NodeRef(mod_id)
    repair!(g)
    return mod_id
end

# ── Proximité de graphe (épine + quartiers) ────────────────────────
# Adjacence NON ORIENTÉE : les NodeRef de node.args sont les arêtes ;
# pas d'index inverse stocké → on le construit en scannant une fois.
function build_adjacency(g::Genome)
    adj = Dict{Int,Set{Int}}(id => Set{Int}() for id in keys(g.nodes))
    for (id, n) in g.nodes
        for a in n.args
            if a isa NodeRef && haskey(adj, a.id)
                push!(adj[id], a.id)
                push!(adj[a.id], id)
            end
        end
    end
    return adj
end

# Distance en hops (BFS). typemax(Int) si non atteignable.
function hop_distance(adj::Dict{Int,Set{Int}}, a::Int, b::Int)
    a == b && return 0
    haskey(adj, a) || return typemax(Int)
    seen = Set{Int}((a,)); frontier = Int[a]; d = 0
    while !isempty(frontier)
        d += 1
        nxt = Int[]
        for u in frontier, w in adj[u]
            w == b && return d
            if !(w in seen)
                push!(seen, w); push!(nxt, w)
            end
        end
        frontier = nxt
    end
    return typemax(Int)
end

# Le « nœud » d'un knob : un knob global affecte tout le son → on l'ancre
# à la sortie (extrémité « espace » du graphe).
_knob_node(g::Genome, kb::Knob) = kb.kind === :control ? g.output_id : kb.node_id

# Matrice de distances knob-à-knob (hops), normalisée dans [0,1].
function knob_graph_distances(g::Genome, knobs::Vector{Knob})
    adj = build_adjacency(g)
    n = length(knobs)
    raw = fill(0.0, n, n)
    maxfinite = 0.0
    for i in 1:n, j in (i + 1):n
        d = hop_distance(adj, _knob_node(g, knobs[i]), _knob_node(g, knobs[j]))
        h = d == typemax(Int) ? Inf : Float64(d)
        raw[i, j] = h; raw[j, i] = h
        isfinite(h) && h > maxfinite && (maxfinite = h)
    end
    scale = maxfinite < 1e-9 ? 1.0 : maxfinite
    D = fill(0.0, n, n)
    for i in 1:n, j in 1:n
        D[i, j] = isfinite(raw[i, j]) ? raw[i, j] / scale : 1.0
    end
    return D
end

# ── Descripteurs temps-domaine (dérivés des samples, sans FFT) ──────
# 5 proxies bon marché : brillance, énergie-grave, bruité, attaque, tenu.
function descriptors_from_samples(s::AbstractVector{<:Real}, sr::Int)
    n = length(s)
    n == 0 && return zeros(Float64, 5)
    pk = 0.0
    @inbounds for v in s
        a = abs(Float64(v)); a > pk && (pk = a)
    end
    pk = pk < 1e-9 ? 1.0 : pk
    # 1. brillance ≈ taux de passage par zéro
    zc = 0
    @inbounds for i in 2:n
        ((Float64(s[i - 1]) < 0) != (Float64(s[i]) < 0)) && (zc += 1)
    end
    brightness = clamp(zc / n * 4, 0.0, 1.0)
    # 2. énergie grave ≈ part captée par un lisseur un-pôle
    lp = 0.0; lo_e = 0.0; tot_e = 0.0
    @inbounds for k in 1:n
        x = Float64(s[k]) / pk
        lp += 0.05 * (x - lp)
        lo_e += lp^2; tot_e += x^2
    end
    lowratio = clamp(tot_e < 1e-12 ? 0.0 : lo_e / tot_e, 0.0, 1.0)
    # 3. bruité ≈ moyenne des |différences premières|
    d1 = 0.0
    @inbounds for i in 2:n
        d1 += abs(Float64(s[i]) - Float64(s[i - 1])) / pk
    end
    noisiness = clamp(d1 / n * 2, 0.0, 1.0)
    # enveloppe RMS par fenêtres ~10 ms
    w = max(1, sr ÷ 100)
    env = Float64[]
    i = 1
    while i <= n
        j = min(n, i + w - 1)
        acc = 0.0
        @inbounds for k in i:j; acc += (Float64(s[k]) / pk)^2; end
        push!(env, sqrt(acc / (j - i + 1)))
        i = j + 1
    end
    penv = 0.0
    for e in env; e > penv && (penv = e); end
    penv = penv < 1e-9 ? 1.0 : penv
    # 4. attaque ≈ 1 − (temps pour atteindre 90% du pic) / durée
    thr = 0.9 * penv; tpk = length(env)
    for (idx, e) in enumerate(env)
        if e >= thr; tpk = idx; break; end
    end
    attack = clamp(1.0 - tpk / max(length(env), 1), 0.0, 1.0)
    # 5. tenu ≈ moyenne/pic de l'enveloppe
    sustainness = clamp((sum(env) / length(env)) / penv, 0.0, 1.0)
    return [brightness, lowratio, noisiness, attack, sustainness]
end

# ── Signatures acoustiques par knob (ce qu'il déplace dans le son) ──
mutable struct KnobSignatures
    vecs::Dict{Int,Vector{Float64}}   # index knob → direction moyenne
    cnt::Dict{Int,Int}
end
KnobSignatures() = KnobSignatures(Dict{Int,Vector{Float64}}(), Dict{Int,Int}())

n_signatures(sigs::KnobSignatures) = length(sigs.cnt)

# Moyenne mobile (EMA) de la DIRECTION du déplacement descripteur.
function update_signature!(sigs::KnobSignatures, idx::Int, delta::Vector{Float64}; β::Float64 = 0.4)
    nrm = sqrt(sum(abs2, delta))
    nrm < 1e-9 && return sigs
    dir = delta ./ nrm
    cur = get(sigs.vecs, idx, zeros(Float64, length(delta)))
    length(cur) == length(dir) || (cur = zeros(Float64, length(dir)))
    sigs.vecs[idx] = (1 - β) .* cur .+ β .* dir
    sigs.cnt[idx] = get(sigs.cnt, idx, 0) + 1
    return sigs
end

# Distance acoustique ∈ [0,1] (cosinus). Knob sans signature → 1 (neutre).
function _ac_dist(sigs::KnobSignatures, i::Int, j::Int)
    a = get(sigs.vecs, i, nothing); b = get(sigs.vecs, j, nothing)
    (a === nothing || b === nothing) && return 1.0
    na = sqrt(sum(abs2, a)); nb = sqrt(sum(abs2, b))
    (na < 1e-9 || nb < 1e-9) && return 1.0
    dotp = sum(a[k] * b[k] for k in 1:min(length(a), length(b)))
    return clamp((1 - dotp / (na * nb)) / 2, 0.0, 1.0)
end

# ── Distance mixte graphe × acoustique ─────────────────────────────
# α monte de 0 vers 0.7 à mesure que les signatures se remplissent.
function mixed_distances(dgraph::Matrix{Float64}, sigs::KnobSignatures, knobs::Vector{Knob})
    n = length(knobs)
    α = clamp(0.7 * n_signatures(sigs) / max(n, 1), 0.0, 0.7)
    α < 1e-9 && return dgraph
    D = fill(0.0, n, n)
    for i in 1:n, j in 1:n
        i == j && continue
        D[i, j] = (1 - α) * dgraph[i, j] + α * _ac_dist(sigs, i, j)
    end
    return D
end

# ── Quartiers mous (clustering glouton par seuil sur la matrice) ───
# Renvoie (labels, force) : force ∈ [0,1] = à quel point le knob est au
# cœur de son quartier (loin du quartier voisin) → la bordure est « molle ».
function soft_quartiers(D::AbstractMatrix; threshold::Float64 = 0.34)
    n = size(D, 1)
    seeds = Int[]; labels = zeros(Int, n)
    for i in 1:n
        best = 0; bd = Inf
        for (ci, s) in enumerate(seeds)
            D[i, s] < bd && (bd = D[i, s]; best = ci)
        end
        if best == 0 || bd > threshold
            push!(seeds, i); labels[i] = length(seeds)
        else
            labels[i] = best
        end
    end
    strength = ones(Float64, n)
    if length(seeds) > 1
        for i in 1:n
            own = seeds[labels[i]]
            do_ = D[i, own]
            no = Inf
            for (ci, s) in enumerate(seeds)
                ci == labels[i] && continue
                D[i, s] < no && (no = D[i, s])
            end
            strength[i] = clamp((no - do_) / (no + do_ + 1e-9), 0.0, 1.0)
        end
    end
    return labels, strength
end
