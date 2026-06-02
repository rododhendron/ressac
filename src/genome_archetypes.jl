# src/genome_archetypes.jl
# Sérialisation native (round-trip pour les graines, sans parser A2)
# + biblio d'archétypes natifs + load/save plugins/synth-seeds/.

import JSON

function _ser_arg(a::Arg)
    a isa ConstArg   && return Dict("t" => "const", "v" => a.value)
    a isa NodeRef    && return Dict("t" => "node",  "id" => a.id)
    return Dict("t" => "ctrl", "name" => String(a.name))   # ControlRef
end

function _deser_arg(d::AbstractDict)::Arg
    t = d["t"]
    t == "const" && return ConstArg(Float64(d["v"]))
    t == "node"  && return NodeRef(Int(d["id"]))
    return ControlRef(Symbol(d["name"]))
end

function serialize_genome(g::Genome)
    nodes = [Dict("id" => n.id, "ugen" => String(n.ugen),
                  "rate" => String(n.rate),
                  "args" => [_ser_arg(a) for a in n.args])
             for n in values(g.nodes)]
    return Dict("nodes" => nodes, "output" => g.output_id,
                "next_id" => g.next_id,
                "controls" => Dict(String(k) => v for (k, v) in g.controls))
end

function deserialize_genome(d::AbstractDict)
    g = Genome()
    for nd in d["nodes"]
        id = Int(nd["id"])
        g.nodes[id] = UGenNode(id, Symbol(nd["ugen"]), Symbol(nd["rate"]),
                               Arg[_deser_arg(a) for a in nd["args"]])
    end
    g.output_id = Int(d["output"])
    g.next_id = Int(get(d, "next_id", maximum(keys(g.nodes); init = 0) + 1))
    if haskey(d, "controls")
        for (k, v) in d["controls"]
            g.controls[Symbol(k)] = Float64(v)
        end
    end
    return g
end

# ── Archétypes natifs ──────────────────────────────────────────────
const _ARCHETYPES = Dict{Symbol,Function}()

function _arch_drone_grave()
    g = Genome()
    osc = add_node!(g, :Saw, :ar, Arg[ControlRef(:freq)])
    flt = add_node!(g, :RLPF, :ar, Arg[NodeRef(osc), ConstArg(400.0), ConstArg(0.3)])
    g.output_id = flt
    return g
end

function _arch_pluck()
    g = Genome()
    osc = add_node!(g, :Pulse, :ar, Arg[ControlRef(:freq), ConstArg(0.5)])
    drv = add_node!(g, :Tanh, :ar, Arg[NodeRef(osc)])
    g.output_id = drv
    return g
end

function _arch_fm_bell()
    g = Genome()
    modu = add_node!(g, :SinOsc, :ar, Arg[ControlRef(:freq), ConstArg(0.0)])
    car  = add_node!(g, :SinOsc, :ar, Arg[NodeRef(modu), ConstArg(0.0)])
    g.output_id = car
    return g
end

function _arch_noise_perc()
    g = Genome()
    nz  = add_node!(g, :WhiteNoise, :ar, Arg[])
    flt = add_node!(g, :HPF, :ar, Arg[NodeRef(nz), ConstArg(2000.0)])
    g.output_id = flt
    return g
end

_ARCHETYPES[:drone_grave] = _arch_drone_grave
_ARCHETYPES[:pluck]       = _arch_pluck
_ARCHETYPES[:fm_bell]     = _arch_fm_bell
_ARCHETYPES[:noise_perc]  = _arch_noise_perc

archetype_names() = sort!(collect(keys(_ARCHETYPES)))
archetype(name::Symbol) = _ARCHETYPES[name]()

# ── Persistance disque ─────────────────────────────────────────────
seed_dir() = joinpath(pwd(), "plugins", "synth-seeds")

function save_seed(name::AbstractString, g::Genome; dir = seed_dir())
    isdir(dir) || mkpath(dir)
    path = joinpath(dir, "$name.json")
    open(path, "w") do io
        JSON.print(io, serialize_genome(g))
    end
    return path
end

function load_seeds(dir = seed_dir())
    out = Dict{Symbol,Genome}()
    isdir(dir) || return out
    for f in readdir(dir)
        endswith(f, ".json") || continue
        nm = Symbol(splitext(f)[1])
        try
            d = JSON.parsefile(joinpath(dir, f))
            out[nm] = deserialize_genome(d)
        catch
        end
    end
    return out
end

function all_seeds(dir = seed_dir())
    merged = Dict{Symbol,Genome}()
    for nm in archetype_names()
        merged[nm] = archetype(nm)
    end
    for (nm, g) in load_seeds(dir)     # user overrides win
        merged[nm] = g
    end
    return merged
end
