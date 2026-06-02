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

function _emit_node(g::Genome, id::Int)
    n = g.nodes[id]
    sp = _emit_special(g, n)
    sp === nothing || return sp
    suffix = get(_RATE_SUFFIX, n.rate, "ar")
    args = join((_emit_arg(g, a) for a in n.args), ", ")
    return "$(n.ugen).$(suffix)($args)"
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
    return string(
        "SynthDef(\\", name, ", { |out = 0, pan = 0, ",
        "freq = 220, sustain = 0.5, gain = 0.5|\n",
        pre,
        "    var sig = ", sig, ";\n",
        post,
        "    sig = sig * gain;\n",
        "    sig = sig * EnvGen.kr(Env.linen(0.01, sustain, 0.1), doneAction: 2);\n",
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
    return string("@synth :", name, " (freq=220, sustain=0.5) ",
                  "SynthDSL.Sig(\"", body, "\")")
end
