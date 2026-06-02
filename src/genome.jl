# src/genome.jl
# Genome = DAG d'UGens typés. Type de donnée pur : aucune dépendance
# SC/UI. Les contrôles (:freq/:sustain/:gain) sont des ControlRef
# utilisables comme arg n'importe où — pas des nœuds.

struct ConstArg;   value::Float64;  end
struct NodeRef;    id::Int;         end
struct ControlRef; name::Symbol;    end   # :freq | :sustain | :gain
const Arg = Union{ConstArg, NodeRef, ControlRef}

mutable struct UGenNode
    id::Int
    ugen::Symbol
    rate::Symbol            # :ar | :kr | :ir
    args::Vector{Arg}
end

mutable struct Genome
    nodes::Dict{Int,UGenNode}
    output_id::Int          # 0 = pas encore de sortie
    next_id::Int
    controls::Dict{Symbol,Float64}   # défauts joués/exportés (freq, sustain, …)
end
Genome() = Genome(Dict{Int,UGenNode}(), 0, 1, default_controls())

const CONTROL_NAMES = (:freq, :sustain, :gain)

# Contrôles éditables d'un son + leurs valeurs par défaut.
default_controls() = Dict{Symbol,Float64}(
    :freq => 220.0, :sustain => 0.5, :gain => 0.5, :release => 0.1)
const CONTROL_EDIT_ORDER = (:freq, :sustain, :gain, :release)
control(g::Genome, name::Symbol) =
    get(g.controls, name, get(default_controls(), name, 0.0))

function add_node!(g::Genome, ugen::Symbol, rate::Symbol, args::Vector{Arg})
    id = g.next_id
    g.nodes[id] = UGenNode(id, ugen, rate, args)
    g.next_id += 1
    return id
end

node(g::Genome, id::Int) = get(g.nodes, id, nothing)

# ── Catalogue UGenSpec ─────────────────────────────────────────────
# Décrit, pour chaque UGen connu, ses rates et ses slots d'argument.
# C'est ce qui rend la mutation type-safe et le rendu correct.

struct SlotSpec
    name::Symbol
    kind::Symbol        # :signal | :scalar | :choice
    default::Float64
    lo::Float64
    hi::Float64
    choices::Vector{Float64}
end
SlotSpec(name, kind, default, lo, hi) =
    SlotSpec(name, kind, default, lo, hi, Float64[])

struct UGenSpec
    name::Symbol
    rates::Vector{Symbol}
    slots::Vector{SlotSpec}
    role::Symbol        # :source | :filter | :math | :env | :mod
end

const UGEN_CATALOG = Dict{Symbol,UGenSpec}()
register_ugen!(s::UGenSpec) = (UGEN_CATALOG[s.name] = s)
ugen_spec(name::Symbol) = get(UGEN_CATALOG, name, nothing)
catalog_by_role(role::Symbol) =
    [s for s in values(UGEN_CATALOG) if s.role === role]

function _install_builtin_ugens!()
    sig(name, def, lo, hi) = SlotSpec(name, :signal, def, lo, hi)   # modulatable control (any rate)
    sca(name, def, lo, hi) = SlotSpec(name, :scalar, def, lo, hi)   # fixed scalar
    aud(name) = SlotSpec(name, :audio, 0, -1, 1)                    # MUST be audio rate
    # sources
    register_ugen!(UGenSpec(:Saw,    [:ar, :kr], [sig(:freq, 220, 20, 8000)], :source))
    register_ugen!(UGenSpec(:SinOsc, [:ar, :kr], [sig(:freq, 220, 20, 8000),
                                                  sca(:phase, 0, 0, 6.283)], :source))
    register_ugen!(UGenSpec(:Pulse,  [:ar, :kr], [sig(:freq, 220, 20, 8000),
                                                  sca(:width, 0.5, 0.01, 0.99)], :source))
    register_ugen!(UGenSpec(:LFTri,  [:ar, :kr], [sig(:freq, 3, 0.01, 40)], :source))
    register_ugen!(UGenSpec(:WhiteNoise, [:ar], SlotSpec[], :source))
    # filters — first input is a true audio-rate signal
    register_ugen!(UGenSpec(:RLPF, [:ar], [aud(:in),
                                           sig(:freq, 1200, 40, 12000),
                                           sca(:rq, 0.5, 0.05, 1.5)], :filter))
    register_ugen!(UGenSpec(:LPF,  [:ar], [aud(:in),
                                           sig(:freq, 1200, 40, 12000)], :filter))
    register_ugen!(UGenSpec(:HPF,  [:ar], [aud(:in),
                                           sig(:freq, 400, 40, 12000)], :filter))
    # math / shaping — operator forms are scalar-safe, no audio-rate need
    register_ugen!(UGenSpec(:MulAdd, [:ar, :kr], [sig(:in, 0, -1, 1),
                                                  sca(:mul, 1, 0, 4),
                                                  sca(:add, 0, -1, 1)], :math))
    register_ugen!(UGenSpec(:Tanh,   [:ar, :kr], [sig(:in, 0, -1, 1)], :math))
    register_ugen!(UGenSpec(:Mix,    [:ar],      [sig(:a, 0, -1, 1),
                                                  sig(:b, 0, -1, 1)], :math))
    # modulation
    register_ugen!(UGenSpec(:LFNoise1, [:kr], [sig(:freq, 4, 0.05, 30)], :mod))
    register_ugen!(UGenSpec(:SinOscKR, [:kr], [sig(:freq, 4, 0.05, 30)], :mod))
    # feedback — FbIn est une FEUILLE (0 slot) : elle lit le bus de
    # feedback (rendu en `LocalIn`), donc le DAG reste acyclique. La
    # boucle réelle se ferme en SC via LocalIn/LocalOut (cf. render).
    register_ugen!(UGenSpec(:FbIn, [:ar], SlotSpec[], :source))
    return nothing
end
_install_builtin_ugens!()
