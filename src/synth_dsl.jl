# Synth DSL — a small Julia layer over SuperCollider's UGen graph.
# Lives in a SUBMODULE so DSL names (lpf, hpf, gain, …) don't collide
# with the top-level Ressac combinators that ship with the same words
# but completely different semantics (SuperDirt OSC params vs SC UGens).
#
# Usage from the patterns pane or REPL:
#
#     using Ressac.SynthDSL
#     sig = saw(:freq) |> rlpf(1200, 0.3) |> tanh_drive(1.5)
#                     |> env_linen(0.01, :sustain, 0.1)
#     @synth :mywob (freq = 220, sustain = 0.5) sig
#
# Or, without the macro:
#
#     play_synth(:mywob, sig; params = (freq = 220, sustain = 0.5))

module SynthDSL

import ..Ressac: _LIVE_SCHEDULER, send_osc, encode, OSCMessage,
                 register_synth!, SynthEntry

export Sig, sc_arg
export saw, sin_osc, pulse, tri, square, impulse_ar
export white, pink, brown, gray
export lfo, lfo_saw, lfo_tri, lfo_pulse
export low_pass, high_pass, band_pass, rlpf, rhpf, comb_n, comb_l, delay_n
export env_perc, env_linen, env_adsr
export tanh_drive, clip, fold, amp, offset
export build_synth, play_synth, @synth

# ────────────────────────────────────────────────────────────────────
# Sig type & rendering
# ────────────────────────────────────────────────────────────────────

"""
    Sig

A SuperCollider expression. The DSL builds these up; `build_synth`
emits the final SynthDef source.
"""
struct Sig
    code::String
end

sc_arg(s::Sig)            = s.code
sc_arg(s::Symbol)         = String(s)
sc_arg(x::Real)           = string(x)
sc_arg(x::AbstractString) = String(x)

# ────────────────────────────────────────────────────────────────────
# Audio-rate oscillators
# ────────────────────────────────────────────────────────────────────

saw(freq)              = Sig("Saw.ar($(sc_arg(freq)))")
sin_osc(freq, phase=0) = Sig("SinOsc.ar($(sc_arg(freq)), $(sc_arg(phase)))")
pulse(freq, width=0.5) = Sig("Pulse.ar($(sc_arg(freq)), $(sc_arg(width)))")
tri(freq)              = Sig("LFTri.ar($(sc_arg(freq)))")
square(freq)           = pulse(freq, 0.5)
impulse_ar(freq)       = Sig("Impulse.ar($(sc_arg(freq)))")

white() = Sig("WhiteNoise.ar")
pink()  = Sig("PinkNoise.ar")
brown() = Sig("BrownNoise.ar")
gray()  = Sig("GrayNoise.ar")

# ────────────────────────────────────────────────────────────────────
# Control-rate modulators
# ────────────────────────────────────────────────────────────────────

lfo(rate; low=-1, high=1) =
    Sig("SinOsc.kr($(sc_arg(rate))).range($(sc_arg(low)), $(sc_arg(high)))")
lfo_saw(rate; low=-1, high=1) =
    Sig("LFSaw.kr($(sc_arg(rate))).range($(sc_arg(low)), $(sc_arg(high)))")
lfo_tri(rate; low=-1, high=1) =
    Sig("LFTri.kr($(sc_arg(rate))).range($(sc_arg(low)), $(sc_arg(high)))")
lfo_pulse(rate; low=0, high=1, width=0.5) =
    Sig("LFPulse.kr($(sc_arg(rate)), 0, $(sc_arg(width))).range($(sc_arg(low)), $(sc_arg(high)))")

# ────────────────────────────────────────────────────────────────────
# Filters — pipe-curried; named to avoid colliding with the SuperDirt
# combinators of the same short names (lpf / hpf / bpf) at top level.
# ────────────────────────────────────────────────────────────────────

low_pass(cutoff)         = (s::Sig) -> Sig("LPF.ar($(sc_arg(s)), $(sc_arg(cutoff)))")
high_pass(cutoff)        = (s::Sig) -> Sig("HPF.ar($(sc_arg(s)), $(sc_arg(cutoff)))")
band_pass(cutoff, q=0.5) = (s::Sig) -> Sig("BPF.ar($(sc_arg(s)), $(sc_arg(cutoff)), $(sc_arg(q)))")
rlpf(cutoff, q=0.5)      = (s::Sig) -> Sig("RLPF.ar($(sc_arg(s)), $(sc_arg(cutoff)), $(sc_arg(q)))")
rhpf(cutoff, q=0.5)      = (s::Sig) -> Sig("RHPF.ar($(sc_arg(s)), $(sc_arg(cutoff)), $(sc_arg(q)))")
comb_n(delay, decay)     = (s::Sig) -> Sig("CombN.ar($(sc_arg(s)), 1.0, $(sc_arg(delay)), $(sc_arg(decay)))")
comb_l(delay, decay)     = (s::Sig) -> Sig("CombL.ar($(sc_arg(s)), 1.0, $(sc_arg(delay)), $(sc_arg(decay)))")
delay_n(time)            = (s::Sig) -> Sig("DelayN.ar($(sc_arg(s)), 1.0, $(sc_arg(time)))")

# ────────────────────────────────────────────────────────────────────
# Envelopes — each multiplies its input by the env, doneAction:2 frees
# the synth when the env completes. Pipe-style.
# ────────────────────────────────────────────────────────────────────

env_perc(attack, release; level=1, curve=-4) = (s::Sig) ->
    Sig("($(sc_arg(s)) * EnvGen.kr(Env.perc($(sc_arg(attack)), $(sc_arg(release)), $(sc_arg(level)), $(sc_arg(curve))), doneAction: 2))")

env_linen(attack, sustain, release) = (s::Sig) ->
    Sig("($(sc_arg(s)) * EnvGen.kr(Env.linen($(sc_arg(attack)), $(sc_arg(sustain)), $(sc_arg(release))), doneAction: 2))")

env_adsr(attack, decay, sustain_level, release; gate=:gate) = (s::Sig) ->
    Sig("($(sc_arg(s)) * EnvGen.kr(Env.adsr($(sc_arg(attack)), $(sc_arg(decay)), $(sc_arg(sustain_level)), $(sc_arg(release))), $(sc_arg(gate)), doneAction: 2))")

# ────────────────────────────────────────────────────────────────────
# Shaping
# ────────────────────────────────────────────────────────────────────

tanh_drive(amount=1) = (s::Sig) -> Sig("(($(sc_arg(s))) * $(sc_arg(amount))).tanh")
clip(low=-1, high=1) = (s::Sig) -> Sig("$(sc_arg(s)).clip($(sc_arg(low)), $(sc_arg(high)))")
fold(low=-1, high=1) = (s::Sig) -> Sig("$(sc_arg(s)).fold($(sc_arg(low)), $(sc_arg(high)))")

# ────────────────────────────────────────────────────────────────────
# Arithmetic on Sig — so `saw(220) * 0.5` reads naturally
# ────────────────────────────────────────────────────────────────────

Base.:*(a::Sig, b::Sig)    = Sig("($(a.code) * $(b.code))")
Base.:*(a::Sig, b::Real)   = Sig("($(a.code) * $b)")
Base.:*(a::Real, b::Sig)   = Sig("($a * $(b.code))")
Base.:*(a::Sig, b::Symbol) = Sig("($(a.code) * $b)")
Base.:*(a::Symbol, b::Sig) = Sig("($a * $(b.code))")
Base.:+(a::Sig, b::Sig)    = Sig("($(a.code) + $(b.code))")
Base.:+(a::Sig, b::Real)   = Sig("($(a.code) + $b)")
Base.:+(a::Real, b::Sig)   = Sig("($a + $(b.code))")
Base.:-(a::Sig, b::Sig)    = Sig("($(a.code) - $(b.code))")
Base.:-(a::Sig, b::Real)   = Sig("($(a.code) - $b)")
Base.:/(a::Sig, b::Real)   = Sig("($(a.code) / $b)")

amp(x)    = (s::Sig) -> s * x
offset(x) = (s::Sig) -> s + x

# ────────────────────────────────────────────────────────────────────
# SynthDef builder + immediate-play helper
# ────────────────────────────────────────────────────────────────────

"""
    build_synth(name, sig; params, pan=0) -> String

Compile a `Sig` chain into a full `SynthDef(\\name, { ... }).add;`
string. `params` is a NamedTuple of synth parameters with their
defaults. Always routes through DirtPan + OffsetOut so the synth
slots into the SuperDirt mix.
"""
function build_synth(name::Symbol, sig::Sig;
                     params::NamedTuple = NamedTuple(),
                     pan = 0)
    param_parts = String["out", "pan = $(pan)"]
    for (k, v) in pairs(params)
        push!(param_parts, "$k = $v")
    end
    param_decl = "|" * join(param_parts, ", ") * "|"
    body = "    OffsetOut.ar(out, DirtPan.ar($(sig.code), ~dirt.numChannels, pan));"
    "SynthDef(\\$name, { $param_decl\n$body\n}).add;\n"
end

"""
    play_synth(name, sig; params, pan=0) -> String

Build the SynthDef and send it to SuperCollider via the same OSC
path that T uses — compiles, syncs, fires once with the synth's
own defaults. Also registers the synth so it shows up in :browse /
:lib / pattern lookups.
"""
function play_synth(name::Symbol, sig::Sig;
                    params::NamedTuple = NamedTuple(),
                    pan = 0)
    src = build_synth(name, sig; params, pan)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return src
    send_osc(sched.osc,
             encode(OSCMessage("/ressac/evalAndPlay",
                                Any[String(name), src])))
    register_synth!(SynthEntry(name, "user-dsl",
                               Dict{String,Any}("description" => "DSL-defined",
                                                "tags" => ["dsl"])))
    src
end

"""
    @synth name params body

Sugar for `play_synth(name, body; params=params)`.

    @synth :mywob (freq=220, sustain=0.5) saw(:freq) |> rlpf(1200, 0.3) |> env_linen(0.01, :sustain, 0.1)
"""
macro synth(name, params, body)
    esc(:(play_synth($name, $body; params = $params)))
end

end # module SynthDSL
