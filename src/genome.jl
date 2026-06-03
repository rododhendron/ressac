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

    # ── Palette élargie ────────────────────────────────────────────
    # sources additionnelles
    register_ugen!(UGenSpec(:VarSaw, [:ar, :kr], [sig(:freq, 220, 20, 8000),
                                                  sca(:iphase, 0, 0, 1),
                                                  sca(:width, 0.5, 0.01, 0.99)], :source))
    register_ugen!(UGenSpec(:Blip,   [:ar], [sig(:freq, 220, 20, 8000),
                                             sca(:numharm, 200, 1, 512)], :source))
    register_ugen!(UGenSpec(:Impulse,[:ar], [sig(:freq, 8, 0.1, 400)], :source))
    register_ugen!(UGenSpec(:LFSaw,  [:ar, :kr], [sig(:freq, 220, 0.1, 4000)], :source))
    register_ugen!(UGenSpec(:PinkNoise, [:ar], SlotSpec[], :source))
    register_ugen!(UGenSpec(:Dust,   [:ar], [sig(:density, 20, 0.1, 400)], :source))
    # générateurs CHAOTIQUES — premier arg = freq d'itération ; SC donne
    # les défauts aux autres args, donc on n'expose que la freq.
    for (nm, lo, hi, def) in ((:LorenzL, 20, 12000, 4000), (:HenonL, 20, 12000, 2000),
                              (:LatoocarfianL, 20, 12000, 2000), (:CuspL, 20, 12000, 2000),
                              (:QuadL, 20, 12000, 2000), (:GbmanL, 20, 8000, 2000),
                              (:StandardL, 20, 12000, 4000), (:FBSineL, 20, 12000, 2000))
        register_ugen!(UGenSpec(nm, [:ar], [sig(:freq, def, lo, hi)], :source))
    end
    register_ugen!(UGenSpec(:Logistic, [:ar], [sca(:chaos, 3.7, 3.5, 4.0),
                                               sig(:freq, 1000, 20, 8000)], :source))
    # filtres additionnels
    register_ugen!(UGenSpec(:BPF,    [:ar], [aud(:in), sig(:freq, 1000, 40, 12000),
                                             sca(:rq, 1.0, 0.1, 4.0)], :filter))
    register_ugen!(UGenSpec(:Resonz, [:ar], [aud(:in), sig(:freq, 1000, 40, 12000),
                                             sca(:bwr, 1.0, 0.05, 4.0)], :filter))
    register_ugen!(UGenSpec(:MoogFF, [:ar], [aud(:in), sig(:freq, 1000, 40, 12000),
                                             sca(:gain, 2.0, 0.0, 4.0)], :filter))
    # effets (entrée audio → traités comme des filtres dans le graphe)
    register_ugen!(UGenSpec(:FreeVerb, [:ar], [aud(:in), sca(:mix, 0.33, 0, 1),
                                               sca(:room, 0.5, 0, 1),
                                               sca(:damp, 0.5, 0, 1)], :filter))
    # waveshapers (special-forms côté render : .fold2 / .clip2)
    register_ugen!(UGenSpec(:Fold2, [:ar, :kr], [sig(:in, 0, -1, 1),
                                                 sca(:amount, 1.0, 0.1, 2.0)], :math))
    register_ugen!(UGenSpec(:Clip2, [:ar, :kr], [sig(:in, 0, -1, 1),
                                                 sca(:amount, 1.0, 0.1, 2.0)], :math))
    # modulateur additionnel
    register_ugen!(UGenSpec(:LFNoise0, [:kr], [sig(:freq, 4, 0.05, 30)], :mod))

    # ── Palette élargie (lot 3) ────────────────────────────────────
    # sources
    register_ugen!(UGenSpec(:Formant, [:ar], [sig(:fundfreq, 220, 20, 2000),
                                              sig(:formfreq, 1000, 200, 4000),
                                              sig(:bwfreq, 200, 50, 2000)], :source))
    register_ugen!(UGenSpec(:SyncSaw, [:ar], [sig(:syncFreq, 100, 20, 2000),
                                              sig(:sawFreq, 440, 20, 4000)], :source))
    register_ugen!(UGenSpec(:Crackle, [:ar], [sca(:chaosParam, 1.5, 1.0, 2.0)], :source))
    # filtres / résonateurs
    register_ugen!(UGenSpec(:Ringz, [:ar], [aud(:in), sig(:freq, 2000, 40, 8000),
                                            sca(:decaytime, 0.5, 0.01, 3.0)], :filter))
    register_ugen!(UGenSpec(:Formlet, [:ar], [aud(:in), sig(:freq, 1000, 40, 8000),
                                              sca(:attacktime, 0.01, 0.001, 0.1),
                                              sca(:decaytime, 0.5, 0.01, 2.0)], :filter))
    register_ugen!(UGenSpec(:OnePole, [:ar], [aud(:in), sca(:coef, 0.5, -0.99, 0.99)], :filter))
    # délais / échos (maxdelaytime > delaytime garanti par les plages)
    register_ugen!(UGenSpec(:CombC, [:ar], [aud(:in), sca(:maxdelay, 0.3, 0.3, 0.5),
                                            sca(:delaytime, 0.1, 0.001, 0.2),
                                            sca(:decaytime, 1.0, 0.1, 5.0)], :filter))
    register_ugen!(UGenSpec(:AllpassC, [:ar], [aud(:in), sca(:maxdelay, 0.3, 0.3, 0.5),
                                               sca(:delaytime, 0.1, 0.001, 0.2),
                                               sca(:decaytime, 1.0, 0.1, 5.0)], :filter))
    # waveshaper bitcrush-ish : .round(quant)
    register_ugen!(UGenSpec(:Round, [:ar, :kr], [sig(:in, 0, -1, 1),
                                                 sca(:quant, 0.1, 0.01, 0.5)], :math))
    # modulateur additionnel
    register_ugen!(UGenSpec(:LFPulseKR, [:kr], [sig(:freq, 4, 0.05, 30),
                                               sca(:iphase, 0, 0, 1),
                                               sca(:width, 0.5, 0.01, 0.99)], :mod))
    return nothing
end
_install_builtin_ugens!()
