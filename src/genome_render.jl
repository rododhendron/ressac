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
    return string(
        "SynthDef(\\", name, ", { |out = 0, pan = 0, ",
        "freq = ", fr, ", sustain = ", sus, ", gain = ", gn, "|\n",
        pre,
        "    var sig = ", sig, ";\n",
        post,
        "    sig = sig * gain;\n",
        "    sig = sig * EnvGen.kr(Env.linen(0.01, sustain, ", rel, "), doneAction: 2);\n",
        "    Out.ar(out, Pan2.ar(sig, pan));\n",
        "}).add;\n")
end

function render_dsl(g::Genome, name::Symbol)
    sig = _safe_signal_expr(g)
    # build_synth attend une EXPRESSION ; pour le feedback on emballe
    # dans une fonction SC inline `{ ... }.value` (toujours une
    # expression unique) afin d'inclure LocalIn/LocalOut.
    body = _has_feedback(g) ?
        "{ var fb = LocalIn.ar(1); var s = $sig; LocalOut.ar(s); s }.value" :
        sig
    fr  = _fmt_const(control(g, :freq))
    sus = _fmt_const(control(g, :sustain))
    return string("@synth :", name, " (freq=", fr, ", sustain=", sus, ") ",
                  "SynthDSL.Sig(\"", body, "\")")
end
