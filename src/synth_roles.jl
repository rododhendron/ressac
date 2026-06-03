# src/synth_roles.jl
# Rôles d'usage = points cibles dans l'espace descripteur acoustique
# (cf. DESCRIPTORS dans nrt_analysis.jl). role_fit mesure la proximité d'un
# son MESURÉ à la cible d'un rôle → terme de ciblage de la sélection (mode A).
# Les cibles sont éditables par l'exemple (mode C, cf. refine_role!).

# Ordre des dimensions (DESCRIPTORS) :
#   1 centroïde · 2 subratio · 3 platitude · 4 attaque · 5 tenue · 6 pitchconf
struct Role
    name::Symbol
    target::Vector{Float64}    # longueur N_DESCRIPTORS, ~[0,1]
    weights::Vector{Float64}   # importance par dimension (≥ 0)
end

const ROLES = Dict{Symbol,Role}()
const ROLE_ORDER = Symbol[]
register_role!(r::Role) = (haskey(ROLES, r.name) || push!(ROLE_ORDER, r.name); ROLES[r.name] = r)
role(name::Symbol) = get(ROLES, name, nothing)

# Cycle de rôle pour l'UI : :none → rôle1 → … → :none.
function cycle_role(cur::Union{Nothing,Symbol}, d::Int)
    order = vcat(:none, ROLE_ORDER)
    i = something(findfirst(==(cur === nothing ? :none : cur), order), 1)
    nxt = order[mod1(i + d, length(order))]
    return nxt === :none ? nothing : nxt
end

function _install_roles!()
    empty!(ROLES); empty!(ROLE_ORDER)
    #            name      cent  sub   flat  atk   tenue pitch     poids: cent sub  flat atk  ten  pit
    register_role!(Role(:basse, [0.12, 0.85, 0.10, 0.45, 0.75, 0.85], [1.0, 1.6, 0.9, 0.5, 0.8, 1.0]))
    register_role!(Role(:kick,  [0.22, 0.78, 0.30, 0.92, 0.15, 0.40], [0.7, 1.2, 0.6, 1.6, 1.5, 0.5]))
    register_role!(Role(:lead,  [0.58, 0.10, 0.12, 0.55, 0.70, 0.90], [1.2, 0.9, 0.9, 0.6, 0.7, 1.3]))
    register_role!(Role(:nappe, [0.40, 0.30, 0.12, 0.20, 0.92, 0.85], [1.0, 0.7, 0.9, 1.0, 1.4, 0.9]))
    register_role!(Role(:voix,  [0.72, 0.08, 0.18, 0.50, 0.82, 0.88], [1.3, 0.8, 0.8, 0.5, 0.8, 1.2]))
    return nothing
end
_install_roles!()

# Distance pondérée RMS (échelle ~[0,1]) → fit = 1 − distance ∈ [0,1].
# Un descripteur de poids nul est ignoré (le rôle ne s'y intéresse pas).
function role_fit(descr::AbstractVector{<:Real}, r::Role)
    n = min(length(descr), length(r.target))
    num = 0.0; den = 0.0
    @inbounds for i in 1:n
        w = r.weights[i]
        num += w * (descr[i] - r.target[i])^2
        den += w
    end
    den < 1e-9 && return 0.0
    return clamp(1.0 - sqrt(num / den), 0.0, 1.0)
end
role_fit(descr::AbstractVector{<:Real}, name::Symbol) =
    (r = role(name); r === nothing ? 0.0 : role_fit(descr, r))

# ── Affinage supervisé (mode C) ────────────────────────────────────
# Déplace la cible d'un rôle vers les exemples POSITIFs (tags +) et à
# l'opposé des NÉGATIFs (tags −), pondéré par `rate`. Renvoie un nouveau
# Role (les templates de base restent intacts).
function refine_role(r::Role, positives::Vector{<:AbstractVector}, negatives::Vector{<:AbstractVector};
                     rate::Float64 = 0.5)
    t = copy(r.target)
    if !isempty(positives)
        centroid = reduce(.+, positives) ./ length(positives)
        t .+= rate .* (centroid .- t)
    end
    if !isempty(negatives)
        centroid = reduce(.+, negatives) ./ length(negatives)
        t .-= 0.5 * rate .* (centroid .- t)        # répulsion plus douce
    end
    return Role(r.name, clamp.(t, 0.0, 1.0), r.weights)
end
