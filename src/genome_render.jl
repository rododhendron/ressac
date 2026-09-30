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
    # Méthodes SC plutôt que classes : ce que les wrappers du DSL écrivent.
    n.ugen === :Softclip && return "($(A(1))).softclip"
    n.ugen === :Cubed    && return "($(A(1))).cubed"
    n.ugen === :Midicps  && return "($(A(1))).midicps"
    n.ugen === :Cpsmidi  && return "($(A(1))).cpsmidi"
    n.ugen === :Fold     && return "($(A(1))).fold($(A(2)), $(A(3)))"
    n.ugen === :Wrap     && return "($(A(1))).wrap($(A(2)), $(A(3)))"
    n.ugen === :Clip     && return "($(A(1))).clip($(A(2)), $(A(3)))"
    n.ugen === :Div      && return "($(A(1)) / $(A(2)))"
    n.ugen === :EnvPerc  && return "Env.perc($(join((A(i) for i in 1:length(n.args)), ", ")))"
    n.ugen === :EnvLinen && return "Env.linen($(join((A(i) for i in 1:length(n.args)), ", ")))"
    n.ugen === :EnvAsr   && return "Env.asr($(join((A(i) for i in 1:length(n.args)), ", ")))"
    n.ugen === :EnvAdsr  && return "Env.adsr($(join((A(i) for i in 1:length(n.args)), ", ")))"
    n.ugen === :Raw      && return "Silent.ar"   # un bloc écrit à la main : pas re-rendable
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

# Fenêtre d'analyse FIXE (s) : on mesure le timbre en régime établi, pas la
# durée de note du génome (la sustain est un contrôle du joueur, pas une
# caractéristique du son). Le caractère temporel intrinsèque (percussif vs
# tenu) émerge des dynamiques internes du graphe sous cette porte fixe.
const _NRT_WINDOW = 0.3

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
    fr  = _fmt_const(control(g, :freq))
    sus = _fmt_const(control(g, :sustain))
    win = _fmt_const(_NRT_WINDOW)
    # SC exige TOUS les `var` en tête de fonction (avant le 1er statement),
    # sinon parse error → sclang reste bloqué. On déclare donc tout d'abord.
    vars = fb ? "fb, sig, chain, centroid, flatness, low, full, subratio, amp, pitchconf" :
                "sig, chain, centroid, flatness, low, full, subratio, amp, pitchconf"
    pre  = fb ? "    fb = LocalIn.ar(1);\n" : ""
    post = fb ? "    LocalOut.ar(sig);\n" : ""
    # Retourne l'EXPRESSION SynthDef (sans .add) : le moteur NRT y appelle
    # `.asBytes` pour le Score ; un appelant live appendrait `.add`.
    return string(
        "SynthDef(\\", name, ", { |out = 0, freq = ", fr,
        ", sustain = ", sus, "|\n",
        "    var ", vars, ";\n",
        pre,
        "    sig = ", sig, ";\n",
        post,
        "    sig = sig * EnvGen.kr(Env.linen(0.01, ", win, ", 0.02), doneAction: 2);\n",
        "    chain = FFT(LocalBuf(1024), sig);\n",
        "    centroid = (SpecCentroid.kr(chain) / 8000).clip(0, 1);\n",
        "    flatness = SpecFlatness.kr(chain).clip(0, 1);\n",
        "    low = Amplitude.kr(LPF.ar(sig, 200), 0.01, 0.05);\n",
        "    full = Amplitude.kr(sig, 0.01, 0.05);\n",
        "    subratio = (low / (full + 1e-4)).clip(0, 1);\n",
        "    amp = Amplitude.kr(sig, 0.001, 0.02).clip(0, 1);\n",
        "    pitchconf = Pitch.kr(sig)[1].clip(0, 1);\n",
        "    Out.ar(out, K2A.ar([centroid, subratio, flatness, amp, pitchconf]));\n",
        "})")
end

# Variante AUDIO (NRT) : le SON réel du génome, mono, avec son enveloppe et
# son gain — pour capturer l'onde complète (viewer). À n'instancier qu'en NRT
# (`Out.ar(0, …)` jouerait aux haut-parleurs sur un serveur live). Comme la
# variante d'analyse : tous les `var` en tête (sinon sclang bloque).
function render_audio_synthdef(g::Genome, name::Symbol)
    sig = _safe_signal_expr(g)
    fb  = _has_feedback(g)
    fr  = _fmt_const(control(g, :freq))
    sus = _fmt_const(control(g, :sustain))
    gn  = _fmt_const(control(g, :gain))
    rel = _fmt_const(control(g, :release))
    vars = fb ? "fb, sig" : "sig"
    pre  = fb ? "    fb = LocalIn.ar(1);\n" : ""
    post = fb ? "    LocalOut.ar(sig);\n" : ""
    return string(
        "SynthDef(\\", name, ", { |out = 0, freq = ", fr,
        ", sustain = ", sus, "|\n",
        "    var ", vars, ";\n",
        pre,
        "    sig = ", sig, ";\n",
        post,
        "    sig = sig * ", gn, ";\n",
        "    sig = sig * EnvGen.kr(Env.linen(0.01, sustain, ", rel, "), doneAction: 2);\n",
        "    Out.ar(out, sig);\n",
        "})")
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

# ── Export DSL : le vocabulaire des wrappers, en pipes ────────────────
# Le graphe s'écrit comme on l'écrirait à la main : une chaîne
# `saw(:freq) |> rlpf(800, 0.3) |> tanh_drive(2)`, les nœuds lus par
# plusieurs autres deviennent des variables `nK`, et un UGen sans
# wrapper passe par `ugen(:Nom, …)` — pipable lui aussi. Le feedback est
# le combinateur `feedback() do fb … end` du DSL.

# UGen → (wrapper, indices des arguments dans l'ordre du wrapper). Pour
# une étape, l'entrée (slot audio) n'y figure pas : elle vient du pipe.
const _DSL_SOURCES = Dict{Symbol,Tuple{String,Vector{Int}}}(
    :Saw => ("saw", [1]), :SinOsc => ("sin_osc", [1, 2]), :Pulse => ("pulse", [1, 2]), :LFTri => ("tri", [1]),
    :WhiteNoise => ("white", Int[]), :PinkNoise => ("pink", Int[]), :BrownNoise => ("brown", Int[]),
    :Dust => ("dust", [1]), :LFNoise0 => ("lf_noise0", [1]), :LFNoise1 => ("lf_noise1", [1]),
    :LFNoise2 => ("lf_noise2", [1]), :Line => ("line", [1, 2, 3]), :XLine => ("x_line", [1, 2, 3]),
    :SinOscKR => ("lfo", [1]), :Impulse => ("impulse_ar", [1]), :Crackle => ("crackle", [1]))
const _DSL_STAGES = Dict{Symbol,Tuple{String,Vector{Int}}}(
    :RLPF => ("rlpf", [2, 3]), :LPF => ("low_pass", [2]), :HPF => ("high_pass", [2]), :BPF => ("band_pass", [2, 3]),
    :BRF => ("band_reject", [2, 3]), :RHPF => ("rhpf", [2, 3]), :MoogFF => ("moog_ff", [2, 3]),
    :BLowPass => ("b_low_pass", [2, 3]), :BHiPass => ("b_high_pass", [2, 3]), :BPeakEQ => ("b_peak_eq", [2, 3, 4]),
    :BLowShelf => ("b_low_shelf", [2, 3, 4]), :BHiShelf => ("b_high_shelf", [2, 3, 4]),
    :FreeVerb => ("free_verb", [2, 3, 4]), :CombC => ("comb_c", [3, 4, 2]), :CombL => ("comb_l", [3, 4, 2]),
    :CombN => ("comb_n", [3, 4, 2]), :AllpassC => ("allpass_c", [3, 4, 2]), :AllpassL => ("allpass_l", [3, 4, 2]),
    :AllpassN => ("allpass_n", [3, 4, 2]), :DelayC => ("delay_c", [3, 2]), :DelayL => ("delay_l", [3, 2]),
    :DelayN => ("delay_n", [3, 2]), :LeakDC => ("leak_dc", [2]), :Decimator => ("decimator", [2, 3]),
    :Pan2 => ("stereo_pan", [2, 3]), :LinPan2 => ("stereo_pan_lin", [2, 3]), :Median => ("median", [1]),
    :Fold2 => ("fold2", [2]), :Clip2 => ("clip2", [2]), :Round => ("round_q", [2]), :Softclip => ("soft_clip", Int[]),
    :Cubed => ("cubic", Int[]), :Fold => ("fold", [2, 3]), :Wrap => ("wrap", [2, 3]), :Clip => ("clip", [2, 3]),
    :Tanh => ("tanh_drive", Int[]), :Decay => ("decay", [2]), :Decay2 => ("decay2", [2, 3]))
const _DSL_ENV_FNS = Dict{Symbol,String}(:EnvPerc => "env_perc", :EnvLinen => "env_linen",
                                         :EnvAsr => "env_asr", :EnvAdsr => "env_adsr")

# Un argument : constante, contrôle, ou l'expression d'un nœud. Comme
# opérande d'un `+`/`*` (operand = true), une chaîne de pipes ou une
# autre opération prend des parenthèses ; comme argument d'un appel ou
# tête d'un pipe, non.
_dsl_arg(g, a::Arg, vars; operand::Bool = false) =
    a isa ConstArg   ? _fmt_const(a.value) :
    a isa ControlRef ? ":$(a.name)" :
    a isa NodeRef    ? _dsl_node_ref(g, a.id, vars; operand = operand) : "0"

# Une expression composée : une chaîne de pipes ou une opération de
# surface (pas celle qui est entre parenthèses ou dans un appel).
function _dsl_is_compound(e::AbstractString)
    occursin(" |> ", e) && return true
    depth = 0
    for (i, c) in enumerate(e)
        c == '(' && (depth += 1); c == ')' && (depth -= 1)
        depth == 0 && c in ('+', '*', '/') && i > 1 && return true
    end
    return false
end

function _dsl_node_ref(g::Genome, id::Int, vars::Dict{Int,String}; operand::Bool = false)
    haskey(vars, id) && return vars[id]
    haskey(g.nodes, id) || return "ugen(:Silent)"
    e = _dsl_node_expr(g, g.nodes[id], vars)
    operand && _dsl_is_compound(e) && return "(" * e * ")"
    return e
end

# Le slot d'entrée d'une étape (voir _bypass_input_slot), ou nothing.
_dsl_input_slot(n::UGenNode) = _bypass_input_slot(n)

# Les arguments d'un wrapper à partir des indices, sans les valeurs par défaut de queue.
_dsl_call_args(g, n, idxs, vars) = join((_dsl_arg(g, n.args[i], vars) for i in idxs if i <= length(n.args)), ", ")

function _dsl_node_expr(g::Genome, n::UGenNode, vars::Dict{Int,String})
    A(i) = _dsl_arg(g, n.args[i], vars)
    u = n.ugen
    u === :FbIn && return "fb"
    u === :Raw && return "ugen(:Silent)"
    O(i) = _dsl_arg(g, n.args[i], vars; operand = true)
    u === :Mix && return "$(O(1)) + $(O(2))"
    u === :Div && return "$(O(1)) / $(O(2))"
    u === :Midicps && return "midicps($(A(1)))"
    u === :Cpsmidi && return "cpsmidi($(A(1)))"
    if u === :MulAdd
        # `x * EnvGen(Env.perc(…), 1)` : c'est `x |> env_perc(…)`.
        mul = n.args[2]
        if mul isa NodeRef && haskey(g.nodes, mul.id) && g.nodes[mul.id].ugen === :EnvGen &&
           length(n.args) >= 3 && n.args[3] isa ConstArg && n.args[3].value == 0.0
            eg = g.nodes[mul.id]
            env = !isempty(eg.args) && eg.args[1] isa NodeRef ? get(g.nodes, eg.args[1].id, nothing) : nothing
            gate_ok = length(eg.args) < 2 || (eg.args[2] isa ConstArg && eg.args[2].value == 1.0)
            if env !== nothing && haskey(_DSL_ENV_FNS, env.ugen) && gate_ok
                fn = _DSL_ENV_FNS[env.ugen]
                pos = env.ugen === :EnvPerc ? [1, 2] : env.ugen === :EnvLinen ? [1, 2, 3] :
                      env.ugen === :EnvAsr ? [1, 2, 3] : [1, 2, 3, 4]
                return "$(A(1)) |> $fn($(_dsl_call_args(g, env, pos, vars)))"
            end
        end
        # `SinOsc.kr(r).range(lo, hi)` est devenu MulAdd(lfo, (hi-lo)/2, (hi+lo)/2) : `lfo(r; low, high)`.
        src = n.args[1] isa NodeRef ? get(g.nodes, n.args[1].id, nothing) : nothing
        if src !== nothing && src.ugen === :SinOscKR && n.args[2] isa ConstArg && length(n.args) >= 3 &&
           n.args[3] isa ConstArg && !haskey(vars, n.args[1].id)
            mm, aa = n.args[2].value, n.args[3].value
            return "lfo($(_dsl_call_args(g, src, [1], vars)); low = $(_fmt_const(aa - mm)), high = $(_fmt_const(aa + mm)))"
        end
        m = _fmt_const(n.args[2] isa ConstArg ? n.args[2].value : 1.0)
        add = length(n.args) >= 3 && n.args[3] isa ConstArg && n.args[3].value == 0.0 ? "" : " + $(O(3))"
        mulstr = n.args[2] isa ConstArg ? m : O(2)
        return "$(O(1)) * $mulstr$add"
    end
    # `((x) * k).tanh` : `x |> tanh_drive(k)`.
    if u === :Tanh && !isempty(n.args) && n.args[1] isa NodeRef && !haskey(vars, n.args[1].id)
        src = get(g.nodes, n.args[1].id, nothing)
        if src !== nothing && src.ugen === :MulAdd && length(src.args) >= 3 && src.args[2] isa ConstArg &&
           src.args[3] isa ConstArg && src.args[3].value == 0.0
            return "$(_dsl_arg(g, src.args[1], vars)) |> tanh_drive($(_fmt_const(src.args[2].value)))"
        end
    end
    if haskey(_DSL_ENV_FNS, u)
        return "SynthDSL.Sig(\"Env.$(lowercase(String(u)[4:end]))($(join((A(i) for i in 1:length(n.args)), ", ")))\")"
    end
    if u === :SinOscKR && length(n.args) >= 1
        return "lfo($(A(1)))"
    elseif u === :LFPulseKR
        return "ugen(:LFPulse, $(_dsl_call_args(g, n, 1:length(n.args), vars)); rate = :kr)"
    end
    if haskey(_DSL_SOURCES, u)
        (fn, idxs) = _DSL_SOURCES[u]
        return "$fn($(_dsl_call_args(g, n, idxs, vars)))"
    end
    # La tête d'un pipe : une somme ou un produit prend des parenthèses
    # (`(a + b) |> f`), une chaîne de pipes continue telle quelle.
    H(i) = (e = A(i); (occursin(r" [+*/] ", e) && !occursin(" |> ", e)) ? "(" * e * ")" : e)
    si = _dsl_input_slot(n)
    if haskey(_DSL_STAGES, u) && si !== nothing && si <= length(n.args)
        (fn, idxs) = _DSL_STAGES[u]
        args = u === :Tanh ? "1" : _dsl_call_args(g, n, idxs, vars)
        return "$(H(si)) |> $fn($args)"
    end
    # Sans wrapper : ugen(:Nom, …), pipable quand il a une entrée.
    spec = ugen_spec(u)
    parts = String[]
    for (i, a) in enumerate(n.args)
        i == si && continue
        code = _dsl_arg(g, a, vars)
        if spec !== nothing && i <= length(spec.slots) && spec.slots[i].kind === :audio && !_is_audio_expr(g, a)
            code = (a isa NodeRef && haskey(g.nodes, a.id) && g.nodes[a.id].rate === :kr) ?
                   "ugen(:K2A, $code)" : "ugen(:DC, $code)"
        end
        push!(parts, code)
    end
    rate = n.rate === :kr ? "; rate = :kr" : ""
    tail = isempty(parts) ? "" : ", " * join(parts, ", ")
    si === nothing && return "ugen(:$(u)$(tail)$rate)"
    return "$(H(si)) |> ugen(:$(u)$(tail)$rate)"
end

# Combien de nœuds lisent chaque nœud : lu deux fois, il devient une variable.
function _dsl_refcounts(g::Genome)
    counts = Dict{Int,Int}()
    for n in values(g.nodes), a in n.args
        a isa NodeRef && (counts[a.id] = get(counts, a.id, 0) + 1)
    end
    return counts
end

# Les morceaux d'une chaîne de pipes, coupée aux ` |> ` de surface
# seulement (pas ceux entre parenthèses).
function _dsl_split_pipes(expr::String)
    parts = String[]; depth = 0; start = 1; i = 1
    cs = collect(expr)
    while i <= length(cs)
        c = cs[i]
        c == '(' && (depth += 1); c == ')' && (depth -= 1)
        if depth == 0 && c == ' ' && i + 3 <= length(cs) && cs[i+1] == '|' && cs[i+2] == '>' && cs[i+3] == ' '
            push!(parts, String(cs[start:i-1])); start = i + 4; i += 4; continue
        end
        i += 1
    end
    push!(parts, String(cs[start:end]))
    return parts
end

# Coupe une longue chaîne de pipes en lignes, les suivantes indentées.
function _dsl_wrap_pipes(expr::String, pad::String; width::Int = 78)
    length(expr) <= width && return expr
    parts = _dsl_split_pipes(expr)
    length(parts) == 1 && return expr
    lines = String[String(parts[1])]
    for p in parts[2:end]
        if length(lines[end]) + 4 + length(p) <= width
            lines[end] *= " |> " * p
        else
            push!(lines, pad * "    |> " * p)
        end
    end
    return join(lines, "\n")
end

# Lignes du corps DSL, indentées de `pad` : les nœuds partagés d'abord
# (`nK = …`), puis la chaîne de sortie, puis la sécurité.
function _dsl_body_lines(g::Genome, pad::String)
    order = _topo_order(g)
    counts = _dsl_refcounts(g)
    vars = Dict{Int,String}()
    for id in order
        g.nodes[id].ugen === :FbIn && (vars[id] = "fb")
    end
    lines = String[]
    k = 0
    for id in order
        n = g.nodes[id]
        n.ugen === :FbIn && continue
        id == g.output_id && continue
        get(counts, id, 0) >= 2 || continue
        k += 1
        expr = _dsl_node_expr(g, n, vars)
        vars[id] = "n$k"
        push!(lines, "$(pad)n$k = " * _dsl_wrap_pipes(expr, pad))
    end
    out = g.output_id == 0 ? "ugen(:Silent)" : _dsl_node_ref(g, g.output_id, vars)
    (occursin(r" [+*/] ", out) && !occursin(" |> ", out)) && (out = "(" * out * ")")   # `(a + b) |> safe()`
    push!(lines, pad * _dsl_wrap_pipes(out * " |> safe()", pad))
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
