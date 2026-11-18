# src/audio_outputs.jl
# Les sorties audio, vues par PipeWire — logique pure, sans app.
#
# SuperCollider sort quatre canaux : 1-2 la sortie principale, 3-4 le
# casque. Ici on lit le graphe PipeWire (`pw-dump`), on y trouve les sorties
# (enceintes, casque filaire, casque Bluetooth…) et les ports de
# SuperCollider, et on calcule quels liens faire ou défaire (`pw-link`) pour
# que 1-2 aillent à la sortie choisie et 3-4 au casque choisi.

import JSON

"Une sortie audio (un « sink » PipeWire)."
struct AudioSink
    id::Int
    name::String              # node.name : stable d'une session à l'autre
    label::String             # ce qu'on lit : « USB Audio Speakers »
    ports::Vector{String}     # ses entrées, dans l'ordre des canaux : « nom:playback_FL »…
    default::Bool             # la sortie par défaut du système
    bluetooth::Bool
end

"Ce qu'il faut du graphe PipeWire pour router SuperCollider."
struct AudioGraph
    sinks::Vector{AudioSink}
    sc_outs::Vector{String}                 # « SuperCollider:out_1 »… ; vide s'il ne tourne pas
    links::Vector{Pair{String,String}}      # sortie => entrée, noms complets
end
AudioGraph() = AudioGraph(AudioSink[], String[], Pair{String,String}[])

_pw_kind(o) = last(split(String(get(o, "type", "")), ':'))
_pw_props(o) = (i = get(o, "info", nothing); i isa AbstractDict ? something(get(i, "props", nothing), Dict{String,Any}()) : Dict{String,Any}())

"""
    parse_pw_dump(json) -> AudioGraph

Lit la sortie de `pw-dump`. Ne lève pas sur un objet inattendu : ce qu'elle
ne reconnaît pas est ignoré.
"""
function parse_pw_dump(json::AbstractString)
    data = JSON.parse(String(json))
    data isa AbstractVector || return AudioGraph()
    node_name = Dict{Int,String}()
    sinks_raw = Tuple{Int,String,String,Bool}[]
    sc_id = nothing
    default_sink = ""
    for o in data
        o isa AbstractDict || continue
        kind = _pw_kind(o)
        if kind == "Node"
            p = _pw_props(o)
            id = Int(get(o, "id", 0))
            name = String(something(get(p, "node.name", nothing), ""))
            node_name[id] = name
            cls = String(something(get(p, "media.class", nothing), ""))
            if cls == "Audio/Sink"
                label = String(something(get(p, "node.description", nothing), get(p, "node.nick", nothing), name))
                bt = startswith(name, "bluez_") || String(something(get(p, "device.api", nothing), "")) == "bluez5"
                push!(sinks_raw, (id, name, label, bt))
            elseif startswith(name, "SuperCollider") && sc_id === nothing
                sc_id = id
            end
        elseif kind == "Metadata"
            for md in something(get(o, "metadata", nothing), [])
                (md isa AbstractDict && get(md, "key", "") == "default.audio.sink") || continue
                v = get(md, "value", nothing)
                v isa AbstractDict && (default_sink = String(something(get(v, "name", nothing), "")))
            end
        end
    end
    # Les ports : (nœud, sens, nom, rang, moniteur), et leur nom complet par id.
    port_full = Dict{Int,String}()
    ports = Tuple{Int,String,String,Int,Bool}[]
    for o in data
        (o isa AbstractDict && _pw_kind(o) == "Port") || continue
        p = _pw_props(o)
        nid = get(p, "node.id", nothing)
        nid isa Integer || continue
        pname = String(something(get(p, "port.name", nothing), ""))
        dir = String(something(get(get(o, "info", Dict()), "direction", nothing), ""))
        rank = get(p, "port.id", 0)
        push!(ports, (Int(nid), dir, pname, rank isa Integer ? Int(rank) : 0, get(p, "port.monitor", false) === true))
        port_full[Int(get(o, "id", 0))] = get(node_name, Int(nid), "") * ":" * pname
    end
    full(nid, pname) = get(node_name, nid, "") * ":" * pname
    sinks = AudioSink[]
    for (id, name, label, bt) in sinks_raw
        mine = sort!([p for p in ports if p[1] == id && p[2] == "input" && !p[5]]; by = p -> p[4])
        isempty(mine) && continue
        push!(sinks, AudioSink(id, name, label, [full(id, p[3]) for p in mine], name == default_sink, bt))
    end
    sort!(sinks; by = s -> (s.bluetooth, lowercase(s.label)))
    sc_outs = String[]
    if sc_id !== nothing
        outs = [p for p in ports if p[1] == sc_id && p[2] == "output" && occursin(r"^out_\d+$", p[3])]
        sort!(outs; by = p -> parse(Int, p[3][5:end]))
        sc_outs = [full(sc_id, p[3]) for p in outs]
    end
    links = Pair{String,String}[]
    for o in data
        (o isa AbstractDict && _pw_kind(o) == "Link") || continue
        i = get(o, "info", nothing)
        i isa AbstractDict || continue
        a = get(port_full, get(i, "output-port-id", -1), nothing)
        b = get(port_full, get(i, "input-port-id", -1), nothing)
        (a === nothing || b === nothing) || push!(links, a => b)
    end
    return AudioGraph(sinks, sc_outs, links)
end

_sink_named(g::AudioGraph, name::AbstractString) =
    isempty(name) ? nothing : (i = findfirst(s -> s.name == name, g.sinks); i === nothing ? nothing : g.sinks[i])

# Gauche et droite d'une sortie (une sortie mono reçoit les deux).
_stereo(s::AudioSink) = (s.ports[1], s.ports[min(2, length(s.ports))])

"""
    routing_plan(g, main, casque) -> (add, remove, problems)

Les liens à faire et à défaire pour que les sorties 1-2 de SuperCollider
aillent à `main` et 3-4 à `casque` (des `node.name` ; vide = ne pas y
toucher pour `main`, pas de casque pour `casque`). Seuls les liens de
SuperCollider vers des sorties audio sont défaits : un enregistreur branché
dessus reste branché. `problems` dit ce qui empêche de router.
"""
function routing_plan(g::AudioGraph, main::AbstractString, casque::AbstractString)
    add = Pair{String,String}[]; remove = Pair{String,String}[]; problems = String[]
    isempty(g.sc_outs) && (push!(problems, "SuperCollider n'est pas lancé — le réglage s'appliquera quand il répondra"); return (add, remove, problems))
    sink_ports = Set(p for s in g.sinks for p in s.ports)
    wanted = Dict{String,Union{Nothing,String}}()         # sortie SC => entrée voulue (nothing : aucune)
    ms = _sink_named(g, main)
    if !isempty(main)
        if ms === nothing
            push!(problems, "la sortie « $main » n'est plus là — r pour rafraîchir")
        elseif length(g.sc_outs) >= 2
            (l, r) = _stereo(ms)
            wanted[g.sc_outs[1]] = l; wanted[g.sc_outs[2]] = r
        end
    end
    if length(g.sc_outs) >= 4
        cs = _sink_named(g, casque)
        if isempty(casque)
            wanted[g.sc_outs[3]] = nothing; wanted[g.sc_outs[4]] = nothing
        elseif cs === nothing
            push!(problems, "le casque « $casque » n'est plus là (éteint ?) — r pour rafraîchir")
        else
            (l, r) = _stereo(cs)
            wanted[g.sc_outs[3]] = l; wanted[g.sc_outs[4]] = r
        end
    elseif !isempty(casque)
        push!(problems, "SuperCollider n'a que $(length(g.sc_outs)) sorties : il en faut 4 pour le casque — relance-le (scripts/superdirt-startup.scd)")
    end
    for (out, target) in wanted
        existing = [b for (a, b) in g.links if a == out && b in sink_ports]
        for b in existing
            b == target || push!(remove, out => b)
        end
        (target === nothing || target in existing) || push!(add, out => target)
    end
    sort!(add; by = first); sort!(remove; by = first)
    return (add, remove, problems)
end

# ── Les deux commandes (remplaçables en test) ────────────────────────

const _PW_DUMP = Ref{Function}(() -> read(pipeline(`pw-dump`; stderr = devnull), String))
const _PW_LINK = Ref{Function}((args::Vector{String}) ->
    success(pipeline(Cmd(vcat(["pw-link"], args)); stdout = devnull, stderr = devnull)))

"""
    audio_graph() -> (AudioGraph, note)

Le graphe courant. `note` dit pourquoi il est vide quand `pw-dump` manque
ou échoue ("" sinon).
"""
function audio_graph()
    try
        return (parse_pw_dump(_PW_DUMP[]()), "")
    catch err
        why = err isa Base.IOError ? "pw-dump introuvable — PipeWire est-il installé ?" :
                                     "pw-dump : " * first(sprint(showerror, err), 80)
        return (AudioGraph(), why)
    end
end

"""
    apply_routing!(g, main, casque) -> (done, problems)

Fait et défait les liens de `routing_plan`. `done` compte ceux qui ont
abouti ; un lien refusé est rapporté dans `problems`.
"""
function apply_routing!(g::AudioGraph, main::AbstractString, casque::AbstractString)
    (add, remove, problems) = routing_plan(g, main, casque)
    done = 0
    for (a, b) in remove
        ok = try _PW_LINK[](["-d", a, b]) catch; false end
        ok ? (done += 1) : push!(problems, "lien non défait : $a → $b")
    end
    for (a, b) in add
        ok = try _PW_LINK[]([a, b]) catch; false end
        ok ? (done += 1) : push!(problems, "lien refusé : $a → $b")
    end
    return (done, problems)
end
