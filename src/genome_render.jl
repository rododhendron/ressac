# src/genome_render.jl
# render_synthdef : Genome -> source SynthDef autonome (audition).
# render_dsl       : Genome -> string @synth (export éditeur).
# Rendu inline (expansion d'expression) — pas de cycles (validité).

const _RATE_SUFFIX = Dict(:ar => "ar", :kr => "kr", :ir => "ir")

_fmt_const(v::Float64) = isinteger(v) ? string(Int(v)) * ".0" : string(v)

function _emit_arg(g::Genome, a::Arg)
    a isa ConstArg   && return _fmt_const(a.value)
    a isa ControlRef && return String(a.name)
    a isa NodeRef    && return _emit_node(g, a.id)
    return "0"
end

# Special operator-form renderers for math/synonym ugens.
function _emit_special(g::Genome, n::UGenNode)
    A(i) = _emit_arg(g, n.args[i])
    n.ugen === :Tanh     && return "($(A(1))).tanh"
    n.ugen === :MulAdd   && return "(($(A(1)) * $(A(2))) + $(A(3)))"
    n.ugen === :Mix      && return "($(A(1)) + $(A(2)))"
    n.ugen === :SinOscKR && return "SinOsc.kr($(A(1)))"
    n.ugen === :Fold2    && return "($(A(1))).fold2($(A(2)))"
    n.ugen === :Clip2    && return "($(A(1))).clip2($(A(2)))"
    n.ugen === :Round    && return "($(A(1))).round($(A(2)))"
    n.ugen === :LFPulseKR && return "LFPulse.kr($(A(1)), $(A(2)), $(A(3)))"
    n.ugen === :FbIn     && return "fb"   # lit le bus de feedback (var fb)
    return nothing
end

_has_feedback(g::Genome) = any(n.ugen === :FbIn for n in values(g.nodes))

# Does this arg's rendered expression actually CARRY audio? We can't
# trust a node's `rate` field alone: a math special-form (Tanh/Mix/
# MulAdd) with only constant inputs renders to a scalar arithmetic
# expression (e.g. `(1.0).tanh`) even at :ar — SC then rejects it as a
# filter input. So we walk the graph: audio comes from a real generator
# / filter at :ar, from FbIn (LocalIn.ar), or flows THROUGH a math node
# only if one of its inputs is itself audio.
function _node_is_audio(g::Genome, id::Int, seen::Set{Int} = Set{Int}())
    (id in seen || !haskey(g.nodes, id)) && return false
    push!(seen, id)
    n = g.nodes[id]
    n.ugen === :FbIn && return true
    spec = ugen_spec(n.ugen)
    spec === nothing && return n.rate === :ar
    spec.role === :math && return any(a -> _is_audio_expr(g, a, seen), n.args)
    return n.rate === :ar && (spec.role === :source || spec.role === :filter)
end

_is_audio_expr(g::Genome, a::Arg, seen::Set{Int} = Set{Int}()) =
    a isa NodeRef ? _node_is_audio(g, a.id, seen) : false

# An :audio slot MUST receive an audio-rate signal. If the expression
# doesn't carry audio, wrap it: a control-rate node via K2A.ar, anything
# else (constant / control / scalar math) via DC.ar.
function _coerce_audio(g::Genome, a::Arg, code::String)
    _is_audio_expr(g, a) && return code
    if a isa NodeRef && haskey(g.nodes, a.id) && g.nodes[a.id].rate === :kr
        return "K2A.ar($code)"
    end
    return "DC.ar($code)"
end

function _emit_node(g::Genome, id::Int)
    n = g.nodes[id]
    sp = _emit_special(g, n)
    sp === nothing || return sp
    suffix = get(_RATE_SUFFIX, n.rate, "ar")
    spec = ugen_spec(n.ugen)
    parts = String[]
    for (i, a) in enumerate(n.args)
        code = _emit_arg(g, a)
        if spec !== nothing && i <= length(spec.slots) && spec.slots[i].kind === :audio
            code = _coerce_audio(g, a, code)
        end
        push!(parts, code)
    end
    return "$(n.ugen).$(suffix)($(join(parts, ", ")))"
end

# Signal expression + safety stage, shared by both renderers.
function _safe_signal_expr(g::Genome)
    body = g.output_id == 0 ? "Silent.ar" : _emit_node(g, g.output_id)
    return "Limiter.ar(LeakDC.ar(Sanitize.ar($body)), 0.95)"
end

function render_synthdef(g::Genome, name::Symbol)
    sig = _safe_signal_expr(g)
    fb  = _has_feedback(g)
    pre  = fb ? "    var fb = LocalIn.ar(1);\n" : ""
    post = fb ? "    LocalOut.ar(sig);\n" : ""   # ferme la boucle (1 frame)
    fr  = _fmt_const(control(g, :freq))
    sus = _fmt_const(control(g, :sustain))
    gn  = _fmt_const(control(g, :gain))
    rel = _fmt_const(control(g, :release))
    # Sonde de niveau : pour les synths d'audition (ga_slotN), on mesure
    # l'amplitude du signal et on la renvoie à Ressac (/ressac/level) →
    # détection de silence sémantique. Mesurée AVANT l'enveloppe pour
    # refléter le niveau intrinsèque, pas le fondu.
    slot = _slot_index(name)
    probe = slot > 0 ?
        string("    SendReply.kr(Impulse.kr(15), '/ressac/level', [", slot,
               ", Amplitude.kr(sig, 0.01, 0.1)]);\n") : ""
    return string(
        "SynthDef(\\", name, ", { |out = 0, pan = 0, ",
        "freq = ", fr, ", sustain = ", sus, ", gain = ", gn, "|\n",
        pre,
        "    var sig = ", sig, ";\n",
        post,
        probe,
        "    sig = sig * gain;\n",
        "    sig = sig * EnvGen.kr(Env.linen(0.01, sustain, ", rel, "), doneAction: 2);\n",
        "    Out.ar(out, Pan2.ar(sig, pan));\n",
        "}).add;\n")
end

# Canaux descripteurs émis par render_analysis_synthdef (dans cet ordre).
# Julia (nrt_analysis.jl) en dérive le vecteur scalaire par candidat :
# centroïde / sub-ratio / platitude moyennés, attaque + forme d'enveloppe
# tirées de la série temporelle d'amplitude, stabilité de hauteur moyennée.
const ANALYSIS_CHANNELS = (:centroid, :subratio, :flatness, :amp, :pitchconf)
const N_ANALYSIS_CHANNELS = length(ANALYSIS_CHANNELS)

# Variante d'ANALYSE (NRT uniquement) : même chaîne de signal, mais la
# sortie n'est PAS du son — ce sont les descripteurs acoustiques, écrits
# comme canaux audio sur le bus de sortie (que le rendu NRT capture dans
# le fichier). Aucune lecture aux haut-parleurs : à n'instancier qu'en
# NRT (sur un serveur live, `Out.ar(0, …)` jouerait ces canaux).
#
# L'enveloppe réelle (linen) est appliquée pour que le canal d'amplitude
# porte la dynamique attaque/sustain/decay du son tel qu'il serait joué.
function render_analysis_synthdef(g::Genome, name::Symbol)
    sig = _safe_signal_expr(g)
    fb  = _has_feedback(g)
    pre  = fb ? "    var fb = LocalIn.ar(1);\n" : ""
    post = fb ? "    LocalOut.ar(sig);\n" : ""
    fr  = _fmt_const(control(g, :freq))
    sus = _fmt_const(control(g, :sustain))
    rel = _fmt_const(control(g, :release))
    return string(
        "SynthDef(\\", name, ", { |out = 0, freq = ", fr,
        ", sustain = ", sus, "|\n",
        pre,
        "    var sig = ", sig, ";\n",
        post,
        "    sig = sig * EnvGen.kr(Env.linen(0.01, sustain, ", rel, "), doneAction: 2);\n",
        "    var chain = FFT(LocalBuf(1024), sig);\n",
        "    var centroid = (SpecCentroid.kr(chain) / 8000).clip(0, 1);\n",
        "    var flatness = SpecFlatness.kr(chain).clip(0, 1);\n",
        "    var low  = Amplitude.kr(LPF.ar(sig, 200), 0.01, 0.05);\n",
        "    var full = Amplitude.kr(sig, 0.01, 0.05);\n",
        "    var subratio = (low / (full + 1e-4)).clip(0, 1);\n",
        "    var amp = Amplitude.kr(sig, 0.001, 0.02).clip(0, 1);\n",
        "    var pitchconf = Pitch.kr(sig)[1].clip(0, 1);\n",
        "    Out.ar(out, K2A.ar([centroid, subratio, flatness, amp, pitchconf]));\n",
        "}).add;\n")
end

# Ordre topologique (entrées avant le nœud) depuis la sortie.
function _topo_order(g::Genome)
    order = Int[]
    seen = Set{Int}()
    function visit(id)
        (id in seen || !haskey(g.nodes, id)) && return
        push!(seen, id)
        for a in g.nodes[id].args
            a isa NodeRef && visit(a.id)
        end
        push!(order, id)
    end
    g.output_id != 0 && visit(g.output_id)
    return order
end

# ── Export DSL propre : bloc begin/end multi-ligne (variables nommées) ──
# Le feedback est représenté par le combinateur `feedback() do fb … end`
# du DSL : les nœuds FbIn renvoient simplement la variable `fb`.
_dsl_arg(g, a::Arg, vars) =
    a isa ConstArg   ? _fmt_const(a.value) :
    a isa ControlRef ? ":$(a.name)" :
    a isa NodeRef    ? get(vars, a.id, "ugen(:Silent)") : "0"

function _dsl_node_expr(g::Genome, n::UGenNode, vars::Dict{Int,String})
    A(i) = _dsl_arg(g, n.args[i], vars)
    n.ugen === :Mix       && return "$(A(1)) + $(A(2))"
    n.ugen === :MulAdd    && return "($(A(1)) * $(A(2))) + $(A(3))"
    n.ugen === :Tanh      && return "$(A(1)) |> tanh_drive(1)"
    n.ugen === :Fold2     && return "$(A(1)) |> fold2($(A(2)))"
    n.ugen === :Clip2     && return "$(A(1)) |> clip2($(A(2)))"
    n.ugen === :Round     && return "$(A(1)) |> round_q($(A(2)))"
    n.ugen === :SinOscKR  && return "ugen(:SinOsc, $(A(1)); rate = :kr)"
    n.ugen === :LFPulseKR && return "ugen(:LFPulse, $(A(1)), $(A(2)), $(A(3)); rate = :kr)"
    spec = ugen_spec(n.ugen)
    parts = String[]
    for (i, a) in enumerate(n.args)
        code = _dsl_arg(g, a, vars)
        if spec !== nothing && i <= length(spec.slots) &&
           spec.slots[i].kind === :audio && !_is_audio_expr(g, a)
            code = (a isa NodeRef && haskey(g.nodes, a.id) && g.nodes[a.id].rate === :kr) ?
                   "ugen(:K2A, $code)" : "ugen(:DC, $code)"
        end
        push!(parts, code)
    end
    rate = n.rate === :kr ? "; rate = :kr" : ""
    return "ugen(:$(n.ugen), $(join(parts, ", "))$rate)"
end

# Lignes du corps DSL (`var = expr`), indentées de `pad`. Les FbIn sont
# liés à `fb` (fourni par le combinateur feedback) et n'émettent rien.
function _dsl_body_lines(g::Genome, pad::String)
    order = _topo_order(g)
    vars = Dict{Int,String}()
    for id in order
        g.nodes[id].ugen === :FbIn && (vars[id] = "fb")
    end
    lines = String[]
    k = 0
    for id in order
        g.nodes[id].ugen === :FbIn && continue
        k += 1
        vars[id] = "n$k"
        push!(lines, "$(pad)n$k = $(_dsl_node_expr(g, g.nodes[id], vars))")
    end
    out = g.output_id == 0 ? "ugen(:Silent)" : vars[g.output_id]
    push!(lines, "$(pad)ugen(:Limiter, ugen(:LeakDC, ugen(:Sanitize, $out)), 0.95)")
    return join(lines, "\n")
end

function render_dsl(g::Genome, name::Symbol)
    fr  = _fmt_const(control(g, :freq))
    sus = _fmt_const(control(g, :sustain))
    head = string("@synth :", name, " (freq=", fr, ", sustain=", sus, ") ")
    if _has_feedback(g)
        return string(head, "feedback() do fb\n", _dsl_body_lines(g, "    "), "\nend\n")
    end
    return string(head, "begin\n", _dsl_body_lines(g, "    "), "\nend\n")
end
