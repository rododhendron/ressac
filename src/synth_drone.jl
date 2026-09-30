# src/synth_drone.jl
# Drones : un synth du DSL tenu par SC (variante à porte `<nom>_drone`),
# dont on module les arguments en direct. Le registre côté Julia est le
# miroir de `~ressacDrones` côté SC : un drone par identifiant (le nom du
# synth quand il vient de l'éditeur, le slot quand il vient de PLAY).
#
# Trois messages OSC, gérés dans scripts/superdirt-startup.scd :
#   /ressac/drone/start id def src k v …   (re)définit + (re)démarre
#   /ressac/drone/set   id def k v …       module (crée le nœud s'il manque)
#   /ressac/drone/stop  id                 relâche (gate 0) ; "*" = tous

"""
    Drone

Un drone vivant : `id` (nœud côté SC), `def` (SynthDef à porte), `synth`
(le synth d'origine), `names` (arguments modulables, dans l'ordre
d'affichage), `defaults` (valeurs du SynthDef), `values` (valeurs
courantes), `origin` (`:editor` ou `:slot`).
"""
mutable struct Drone
    id::Symbol
    def::Symbol
    synth::Symbol
    names::Vector{Symbol}
    defaults::Dict{Symbol,Float64}
    values::Dict{Symbol,Float64}
    origin::Symbol
end

# Le registre est touché par l'interface (pane, D) et par le scheduler
# (miroir des événements PLAY, sur son propre thread) : tout passe par
# le verrou, et `drone_list()` rend une copie à parcourir sans lui.
const _DRONES = Drone[]
const _DRONES_LOCK = ReentrantLock()

drone_list() = lock(() -> copy(_DRONES), _DRONES_LOCK)
drone_get(id::Symbol) = lock(_DRONES_LOCK) do
    i = findfirst(d -> d.id === id, _DRONES)
    i === nothing ? nothing : _DRONES[i]
end
drone_running(id::Symbol) = drone_get(id) !== nothing

# Arguments modulables d'un synth à partir de ses paramètres effectifs :
# les numériques, sans `gate`, plus `release` (la porte l'ajoute).
function drone_params(eff::NamedTuple)
    names = Symbol[]; defaults = Dict{Symbol,Float64}()
    for (k, v) in pairs(eff)
        (k === :gate || !(v isa Real)) && continue
        push!(names, k); defaults[k] = Float64(v)
    end
    if !(:release in names)
        push!(names, :release); defaults[:release] = 0.1
    end
    return names, defaults
end

function _drone_send(address::AbstractString, args::Vector{Any})
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return false
    send_osc(sched.osc, encode(OSCMessage(address, args)))
    return true
end

_drone_kv(d::Drone) = begin
    args = Any[]
    for k in d.names
        push!(args, String(k)); push!(args, Float32(d.values[k]))
    end
    args
end

"""
    drone_start!(id, synth, def, src, names, defaults; values, origin) -> Drone

Enregistre le drone et l'envoie à SC : `src` (peut être vide) est
interprété avant le démarrage, puis le nœud part avec `values` (les
défauts par défaut). Un drone déjà vivant sous cet `id` est relâché par
SC juste avant.
"""
function drone_start!(id::Symbol, synth::Symbol, def::Symbol, src::AbstractString,
                      names::Vector{Symbol}, defaults::Dict{Symbol,Float64};
                      values::Dict{Symbol,Float64} = copy(defaults), origin::Symbol = :editor)
    vals = Dict{Symbol,Float64}(k => get(values, k, defaults[k]) for k in names)
    d = Drone(id, def, synth, copy(names), copy(defaults), vals, origin)
    _drone_put!(d)
    _drone_send("/ressac/drone/start", vcat(Any[String(id), String(def), String(src)], _drone_kv(d)))
    return d
end

function _drone_put!(d::Drone)
    lock(_DRONES_LOCK) do
        i = findfirst(x -> x.id === d.id, _DRONES)
        i === nothing ? push!(_DRONES, d) : (_DRONES[i] = d)
    end
    return d
end

"""
    drone_set!(d, key, val) -> Float64

Pose `key = val` sur le nœud vivant et dans le registre.
"""
function drone_set!(d::Drone, key::Symbol, val::Real)
    v = Float64(val)
    lock(() -> (d.values[key] = v), _DRONES_LOCK)
    _drone_send("/ressac/drone/set", Any[String(d.id), String(d.def), String(key), Float32(v)])
    return v
end

"""
    drone_stop!(id) -> Bool

Relâche le drone `id` (gate 0, la queue dure `release`). `false` s'il
n'était pas enregistré.
"""
function drone_stop!(id::Symbol)
    found = lock(_DRONES_LOCK) do
        i = findfirst(d -> d.id === id, _DRONES)
        i === nothing ? false : (deleteat!(_DRONES, i); true)
    end
    found || return false
    _drone_send("/ressac/drone/stop", Any[String(id)])
    return true
end

"""
    drone_stop_all!() -> Int

Relâche tous les drones. Renvoie combien étaient enregistrés.
"""
function drone_stop_all!()
    n = lock(_DRONES_LOCK) do
        k = length(_DRONES); empty!(_DRONES); k
    end
    n == 0 || _drone_send("/ressac/drone/stop", Any["*"])
    return n
end

# ── Côté PLAY : un slot qui tient son synth ──────────────────────────
# `@d1 :acid |> drone() |> lpf("<400 800>")` : le scheduler traduit chaque
# événement en /ressac/drone/set (SC crée le nœud au premier). Le registre
# suit ces envois pour que la pane MODULATION montre et module le drone
# du slot ; changer ou vider le slot relâche le nœud.

_drone_flag(cm::AbstractDict) = (v = get(cm, :drone, nothing); v isa Real && v != 0)

"""
    _drone_mirror!(slot, msg)

Reflète un `/ressac/drone/set` émis pour `slot` dans le registre : crée le
drone (origine `:slot`, défauts du synth enregistré) ou met ses valeurs à
jour. Appelé par le scheduler juste avant l'envoi.
"""
function _drone_mirror!(slot::Symbol, msg::OSCMessage)
    def = Symbol(msg.args[2])
    synth = Symbol(replace(String(def), r"_drone$" => ""))
    pairs = Pair{Symbol,Float64}[]
    for i in 3:2:length(msg.args) - 1
        v = msg.args[i + 1]
        v isa Real && push!(pairs, Symbol(msg.args[i]) => Float64(v))
    end
    lock(_DRONES_LOCK) do
        i = findfirst(d -> d.id === slot, _DRONES)
        if i === nothing
            names = Symbol[k for (k, _) in pairs]
            defaults = Dict{Symbol,Float64}()
            for (k, v) in _user_synth_params(synth)
                v isa Real || continue
                defaults[Symbol(k)] = Float64(v)
                Symbol(k) in names || push!(names, Symbol(k))
            end
            haskey(defaults, :release) || (defaults[:release] = 0.1)
            :release in names || push!(names, :release)
            for (k, _) in pairs
                haskey(defaults, k) || (defaults[k] = 0.0)
            end
            vals = copy(defaults)
            for (k, v) in pairs; vals[k] = v; end
            push!(_DRONES, Drone(slot, def, synth, names, defaults, vals, :slot))
        else
            d = _DRONES[i]
            for (k, v) in pairs
                k in d.names || (push!(d.names, k); d.defaults[k] = 0.0)
                d.values[k] = v
            end
        end
    end
    return nothing
end

# Relâche le drone tenu par `slot` (s'il vient de PLAY).
function _drone_slot_release!(slot::Symbol)
    d = drone_get(slot)
    (d === nothing || d.origin !== :slot) && return false
    return drone_stop!(slot)
end

# Relâche tous les drones tenus par des slots (hush du scheduler).
function _drone_slots_release!()
    for d in drone_list()
        d.origin === :slot && drone_stop!(d.id)
    end
    return nothing
end

# Un pas de modulation. Les grandeurs « fréquence » (positives, défaut
# ≥ 10) avancent en log, 24 pas par octave ; le reste en linéaire, 24 pas
# pour la valeur du défaut (au moins 1).
function drone_step(cur::Float64, default::Float64, steps::Int)
    if cur > 0 && default >= 10
        return clamp(cur * 2.0^(steps / 24), 1e-3, 1e6)
    end
    unit = max(abs(default), 1.0) / 24
    return clamp(cur + steps * unit, -1e6, 1e6)
end
