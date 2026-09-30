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
# Dans le catalogue pour être sculptés et expliqués, mais pas tirés par
# la mutation ni par `o` : un bloc opaque, des tables, des conversions.
const _NOT_FOR_MUTATION = Set{Symbol}((:Raw, :Klang, :Div, :Midicps, :Cpsmidi, :K2A, :DC,
                                       :EnvGen, :EnvPerc, :EnvLinen, :EnvAsr, :EnvAdsr))
catalog_by_role(role::Symbol) =
    [s for s in values(UGEN_CATALOG) if s.role === role && !(s.name in _NOT_FOR_MUTATION)]

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

    # ── Palette du DSL écrit à la main ─────────────────────────────
    # Tout ce que les wrappers de SynthDSL produisent (synth_dsl.jl) doit
    # se sculpter avec des knobs nommés et s'expliquer avec un rôle. Les
    # rôles :env (enveloppes, rampes), :fx (délais, réverbes) et :space
    # (panoramique) sont hors de la palette de mutation de l'explorateur,
    # qui ne tire que dans :source / :filter / :math / :mod.
    # sources
    register_ugen!(UGenSpec(:BrownNoise, [:ar], SlotSpec[], :source))
    register_ugen!(UGenSpec(:GrayNoise,  [:ar], SlotSpec[], :source))
    register_ugen!(UGenSpec(:ClipNoise,  [:ar], SlotSpec[], :source))
    register_ugen!(UGenSpec(:Dust2,      [:ar], [sig(:density, 4, 0.1, 200)], :source))
    register_ugen!(UGenSpec(:Klang,      [:ar], [sca(:specs, 0, 0, 0), sca(:freqscale, 1, 0.1, 4), sca(:freqoffset, 0, 0, 1000)], :source))
    register_ugen!(UGenSpec(:Raw,        [:ar], SlotSpec[], :source))        # bloc SC opaque `{ … }`
    # enveloppes, rampes, lissages
    register_ugen!(UGenSpec(:Line,     [:kr, :ar], [sca(:start, 0, -20000, 20000), sca(:end, 1, -20000, 20000), sig(:dur, 1, 0.001, 30)], :env))
    register_ugen!(UGenSpec(:XLine,    [:kr, :ar], [sca(:start, 1, 0.001, 20000), sca(:end, 2, 0.001, 20000), sig(:dur, 1, 0.001, 30)], :env))
    register_ugen!(UGenSpec(:Lag,      [:kr, :ar], [aud(:in), sca(:time, 0.1, 0, 5)], :env))
    register_ugen!(UGenSpec(:Lag2,     [:kr, :ar], [aud(:in), sca(:time, 0.1, 0, 5)], :env))
    register_ugen!(UGenSpec(:Lag3,     [:kr, :ar], [aud(:in), sca(:time, 0.1, 0, 5)], :env))
    register_ugen!(UGenSpec(:EnvGen,   [:kr, :ar], [sig(:env, 0, 0, 0), sig(:gate, 1, 0, 1)], :env))
    register_ugen!(UGenSpec(:EnvPerc,  [:kr], [sca(:attack, 0.01, 0.0005, 5), sca(:release, 1, 0.005, 20), sca(:level, 1, 0, 2), sca(:curve, -4, -12, 12)], :env))
    register_ugen!(UGenSpec(:EnvLinen, [:kr], [sca(:attack, 0.01, 0.0005, 5), sca(:sustain, 1, 0.005, 30), sca(:release, 1, 0.005, 20), sca(:level, 1, 0, 2), sca(:curve, 0, -12, 12)], :env))
    register_ugen!(UGenSpec(:EnvAsr,   [:kr], [sca(:attack, 0.01, 0.0005, 5), sca(:level, 1, 0, 2), sca(:release, 1, 0.005, 20), sca(:curve, -4, -12, 12)], :env))
    register_ugen!(UGenSpec(:EnvAdsr,  [:kr], [sca(:attack, 0.01, 0.0005, 5), sca(:decay, 0.3, 0.005, 10), sca(:sustain, 0.5, 0, 1), sca(:release, 1, 0.005, 20), sca(:level, 1, 0, 2), sca(:curve, -4, -12, 12)], :env))
    register_ugen!(UGenSpec(:Decay,    [:ar, :kr], [aud(:in), sca(:decay, 1, 0.01, 10)], :env))
    register_ugen!(UGenSpec(:Decay2,   [:ar, :kr], [aud(:in), sca(:attack, 0.01, 0.001, 5), sca(:decay, 1, 0.01, 10)], :env))
    # filtres
    register_ugen!(UGenSpec(:BRF,      [:ar], [aud(:in), sig(:freq, 800, 40, 12000), sca(:rq, 0.5, 0.05, 4)], :filter))
    register_ugen!(UGenSpec(:RHPF,     [:ar], [aud(:in), sig(:freq, 800, 40, 12000), sca(:rq, 0.5, 0.05, 4)], :filter))
    register_ugen!(UGenSpec(:LeakDC,   [:ar], [aud(:in), sca(:coef, 0.995, 0.9, 0.9999)], :filter))
    register_ugen!(UGenSpec(:Median,   [:ar], [sca(:length, 3, 1, 31), aud(:in)], :filter))
    register_ugen!(UGenSpec(:BLowPass, [:ar], [aud(:in), sig(:freq, 1200, 40, 18000), sca(:rq, 0.7, 0.05, 4)], :filter))
    register_ugen!(UGenSpec(:BHiPass,  [:ar], [aud(:in), sig(:freq, 400, 40, 18000), sca(:rq, 0.7, 0.05, 4)], :filter))
    register_ugen!(UGenSpec(:BPeakEQ,  [:ar], [aud(:in), sig(:freq, 1200, 40, 18000), sca(:rq, 0.7, 0.05, 4), sca(:db, 0, -24, 24)], :filter))
    register_ugen!(UGenSpec(:BLowShelf, [:ar], [aud(:in), sig(:freq, 300, 40, 18000), sca(:rs, 0.7, 0.05, 4), sca(:db, 0, -24, 24)], :filter))
    register_ugen!(UGenSpec(:BHiShelf, [:ar], [aud(:in), sig(:freq, 4000, 40, 18000), sca(:rs, 0.7, 0.05, 4), sca(:db, 0, -24, 24)], :filter))
    # délais, réverbes, modulations d'effet
    register_ugen!(UGenSpec(:DelayN,   [:ar], [aud(:in), sca(:maxdelay, 1, 0.01, 5), sig(:delay, 0.2, 0.0001, 5)], :fx))
    register_ugen!(UGenSpec(:DelayL,   [:ar], [aud(:in), sca(:maxdelay, 1, 0.01, 5), sig(:delay, 0.2, 0.0001, 5)], :fx))
    register_ugen!(UGenSpec(:DelayC,   [:ar], [aud(:in), sca(:maxdelay, 1, 0.01, 5), sig(:delay, 0.2, 0.0001, 5)], :fx))
    register_ugen!(UGenSpec(:CombN,    [:ar], [aud(:in), sca(:maxdelay, 1, 0.01, 5), sig(:delay, 0.2, 0.0001, 5), sca(:decay, 1, 0.01, 20)], :fx))
    register_ugen!(UGenSpec(:CombL,    [:ar], [aud(:in), sca(:maxdelay, 1, 0.01, 5), sig(:delay, 0.2, 0.0001, 5), sca(:decay, 1, 0.01, 20)], :fx))
    register_ugen!(UGenSpec(:AllpassN, [:ar], [aud(:in), sca(:maxdelay, 1, 0.01, 5), sig(:delay, 0.05, 0.0001, 5), sca(:decay, 1, 0.01, 20)], :fx))
    register_ugen!(UGenSpec(:AllpassL, [:ar], [aud(:in), sca(:maxdelay, 1, 0.01, 5), sig(:delay, 0.05, 0.0001, 5), sca(:decay, 1, 0.01, 20)], :fx))
    register_ugen!(UGenSpec(:GVerb,    [:ar], [aud(:in), sca(:roomsize, 10, 1, 300), sca(:revtime, 3, 0.1, 100), sca(:damping, 0.5, 0, 1), sca(:inputbw, 0.5, 0, 1), sca(:spread, 15, 0, 43), sca(:drylevel, 1, 0, 1), sca(:earlyreflevel, 0.7, 0, 1), sca(:taillevel, 0.5, 0, 1)], :fx))
    # espace
    register_ugen!(UGenSpec(:Pan2,     [:ar], [aud(:in), sig(:pos, 0, -1, 1), sca(:level, 1, 0, 2)], :space))
    register_ugen!(UGenSpec(:LinPan2,  [:ar], [aud(:in), sig(:pos, 0, -1, 1), sca(:level, 1, 0, 2)], :space))
    register_ugen!(UGenSpec(:Balance2, [:ar], [aud(:left), aud(:right), sig(:pos, 0, -1, 1), sca(:level, 1, 0, 2)], :space))
    register_ugen!(UGenSpec(:Rotate2,  [:ar], [aud(:x), aud(:y), sig(:pos, 0, -1, 1)], :space))
    register_ugen!(UGenSpec(:Splay,    [:ar], [aud(:in), sca(:spread, 1, 0, 1), sca(:level, 1, 0, 2), sca(:center, 0, -1, 1)], :space))
    # mise en forme, maths
    register_ugen!(UGenSpec(:Softclip, [:ar, :kr], [sig(:in, 0, -1, 1)], :math))
    register_ugen!(UGenSpec(:Cubed,    [:ar, :kr], [sig(:in, 0, -1, 1)], :math))
    register_ugen!(UGenSpec(:Fold,     [:ar, :kr], [sig(:in, 0, -1, 1), sca(:lo, -1, -2, 0), sca(:hi, 1, 0, 2)], :math))
    register_ugen!(UGenSpec(:Wrap,     [:ar, :kr], [sig(:in, 0, -1, 1), sca(:lo, -1, -2, 0), sca(:hi, 1, 0, 2)], :math))
    register_ugen!(UGenSpec(:Clip,     [:ar, :kr], [sig(:in, 0, -1, 1), sca(:lo, -1, -2, 0), sca(:hi, 1, 0, 2)], :math))
    register_ugen!(UGenSpec(:Decimator, [:ar], [aud(:in), sca(:rate, 44100, 1000, 48000), sca(:bits, 24, 1, 24)], :math))
    register_ugen!(UGenSpec(:Div,      [:ar, :kr], [sig(:a, 0, -1, 1), sig(:b, 1, -1, 1)], :math))
    register_ugen!(UGenSpec(:Midicps,  [:ar, :kr], [sig(:in, 60, 0, 127)], :math))
    register_ugen!(UGenSpec(:Cpsmidi,  [:ar, :kr], [sig(:in, 220, 20, 20000)], :math))
    register_ugen!(UGenSpec(:K2A,      [:ar], [sig(:in, 0, -1, 1)], :math))
    register_ugen!(UGenSpec(:DC,       [:ar, :kr], [sca(:in, 0, -1, 1)], :math))
    return nothing
end
_install_builtin_ugens!()

# ── Énergie / coût métabolique ─────────────────────────────────────
# Chaque nœud a un COÛT. L'énergie d'un génome = somme des coûts. La
# pression de parcimonie (cf. ga_engine / mutate) pousse le système à
# « payer » sa complexité : un générateur de plus coûte cher, une
# modulation presque rien → on favorise la richesse PAR MODULATION
# plutôt que par empilement de sources.
const _ROLE_COST = Dict{Symbol,Float64}(
    :source => 3.0, :filter => 2.0, :math => 1.0, :mod => 0.5, :env => 0.5,
    :fx => 3.0, :space => 1.0)

# Surcharges par UGen : les briques lourdes (DSP/perception) coûtent plus.
const _UGEN_COST = Dict{Symbol,Float64}(
    :FreeVerb => 4.0, :Formlet => 3.0, :Ringz => 2.5,
    :CombC => 3.0, :AllpassC => 3.0,
    :LorenzL => 4.0, :HenonL => 4.0, :LatoocarfianL => 4.0, :CuspL => 4.0,
    :QuadL => 4.0, :GbmanL => 4.0, :StandardL => 4.0, :FBSineL => 4.0,
    :Logistic => 4.0, :FbIn => 0.5)

function node_cost(u::Symbol)
    haskey(_UGEN_COST, u) && return _UGEN_COST[u]
    spec = ugen_spec(u)
    return spec === nothing ? 1.0 : get(_ROLE_COST, spec.role, 1.0)
end

genome_energy(g::Genome) =
    sum(node_cost(n.ugen) for n in values(g.nodes); init = 0.0)
