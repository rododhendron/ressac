# Synth DSL — a small Julia layer over SuperCollider's UGen graph.
#
# Goals: minimise boilerplate, read like an Elixir pipeline, compile
# straight to SC source. Lives in a submodule so DSL names don't clash
# with top-level Ressac combinators that share words but mean different
# things (Ressac.lpf is a SuperDirt OSC param; SynthDSL.low_pass is the
# SC LPF UGen).
#
# Minimal usage (no params required — they're auto-inferred):
#
#     using Ressac.SynthDSL
#     @synth :mywob saw(:freq) |> rlpf(1200, 0.3)
#
# The minimal call gives you:
#   • Default params: freq = 220, sustain = 0.5, gain = 0.5
#   • An auto-appended Env.linen envelope (doneAction:2) so the synth
#     frees itself when sustain elapses
#   • An auto-multiply by :gain at the end
#   • OffsetOut + DirtPan routing to SuperDirt
#
# Override anything explicitly when you need to:
#
#     @synth :drone (freq=110, sustain=999) (auto_env=false,) saw(:freq) |> rlpf(800, 0.3)
#     # → no auto-free, runs until you :hush

module SynthDSL

import ..Ressac: _LIVE_SCHEDULER, send_osc, encode, OSCMessage,
                 register_synth!, SynthEntry

# Re-export the whole UGen surface so `using Ressac.SynthDSL` brings
# everything in scope at once.
export Sig, sc_arg
# Oscillators
export saw, sin_osc, pulse, tri, square, var_saw, blip, formant, klang
export impulse_ar, impulse_kr
# Noise
export white, pink, brown, gray, clip_noise, crackle, dust, dust2
export lf_noise0, lf_noise1, lf_noise2
# Modulators
export lfo, lfo_saw, lfo_tri, lfo_pulse, lf_cub, lf_par
export line, x_line, ramp_kr, lag_kr, lag2_kr, lag3_kr
# Filters
export low_pass, high_pass, band_pass, band_reject
export rlpf, rhpf, moog_ff, leak_dc, median, slope_kr
export b_low_pass, b_high_pass, b_peak_eq, b_low_shelf, b_high_shelf
# Delays / reverb
export delay_n, delay_l, delay_c
export comb_n, comb_l, comb_c
export allpass_n, allpass_l, allpass_c
export free_verb, g_verb, decay, decay2
# Spatial
export stereo_pan, stereo_pan_lin, stereo_balance, stereo_rotate, splay, mix_sigs
# Distortion / shaping
export tanh_drive, soft_clip, cubic, clip, fold, wrap, decimator
export amp, offset, abs_sig, sqrt_sig, pow_sig
# Envelopes
export env_perc, env_linen, env_adsr, env_asr, env_cutoff, env_sine
export env_dadsr, env_pairs
# Triggers / pitch
export trig_kr, t_delay, pitch_shift, freq_shift, vibrato_sig
# Rate conversion
export to_kr, to_ar
# Buffers
export play_buf, buf_rd
# Sequence helpers
export demand_seq, demand_white, t_rand
# Top-level builders
export build_synth, play_synth, @synth, synth_source

# ════════════════════════════════════════════════════════════════════
# Sig type & rendering
# ════════════════════════════════════════════════════════════════════

"""
    Sig

A SuperCollider expression. Operators and curried filters thread it
through the pipeline.
"""
struct Sig
    code::String
end

sc_arg(s::Sig)            = s.code
sc_arg(s::Symbol)         = String(s)
sc_arg(x::Real)           = string(x)
sc_arg(x::Bool)           = string(x)
sc_arg(x::AbstractString) = String(x)
sc_arg(xs::AbstractVector) = "[" * join(sc_arg.(xs), ", ") * "]"

# Render an SC symbol literal (e.g. `\lin`). Used for env curves and
# any other place where SC expects a backslash-prefixed Symbol.
sc_sym(s::Symbol)         = "\\" * String(s)
sc_sym(s::AbstractString) = startswith(s, "\\") ? String(s) : "\\" * String(s)

# ════════════════════════════════════════════════════════════════════
# Audio-rate oscillators
# ════════════════════════════════════════════════════════════════════

saw(freq)              = Sig("Saw.ar($(sc_arg(freq)))")
sin_osc(freq, phase=0) = Sig("SinOsc.ar($(sc_arg(freq)), $(sc_arg(phase)))")
pulse(freq, width=0.5) = Sig("Pulse.ar($(sc_arg(freq)), $(sc_arg(width)))")
tri(freq)              = Sig("LFTri.ar($(sc_arg(freq)))")
square(freq)           = pulse(freq, 0.5)
var_saw(freq, width=0.5) = Sig("VarSaw.ar($(sc_arg(freq)), 0, $(sc_arg(width)))")
blip(freq, numharm=200)  = Sig("Blip.ar($(sc_arg(freq)), $(sc_arg(numharm)))")
formant(fund, form, bw)  = Sig("Formant.ar($(sc_arg(fund)), $(sc_arg(form)), $(sc_arg(bw)))")
klang(freqs, amps=nothing, phases=nothing) = begin
    f = sc_arg(freqs)
    a = amps === nothing ? "nil" : sc_arg(amps)
    p = phases === nothing ? "nil" : sc_arg(phases)
    Sig("Klang.ar(`[$f, $a, $p])")
end
impulse_ar(freq) = Sig("Impulse.ar($(sc_arg(freq)))")
impulse_kr(freq) = Sig("Impulse.kr($(sc_arg(freq)))")

# ════════════════════════════════════════════════════════════════════
# Noise sources
# ════════════════════════════════════════════════════════════════════

white()      = Sig("WhiteNoise.ar")
pink()       = Sig("PinkNoise.ar")
brown()      = Sig("BrownNoise.ar")
gray()       = Sig("GrayNoise.ar")
clip_noise() = Sig("ClipNoise.ar")
crackle(chaos=1.95)    = Sig("Crackle.ar($(sc_arg(chaos)))")
dust(density=10)       = Sig("Dust.ar($(sc_arg(density)))")
dust2(density=10)      = Sig("Dust2.ar($(sc_arg(density)))")
lf_noise0(rate)        = Sig("LFNoise0.kr($(sc_arg(rate)))")
lf_noise1(rate)        = Sig("LFNoise1.kr($(sc_arg(rate)))")
lf_noise2(rate)        = Sig("LFNoise2.kr($(sc_arg(rate)))")

# ════════════════════════════════════════════════════════════════════
# Control-rate modulators / lines
# ════════════════════════════════════════════════════════════════════

lfo(rate; low=-1, high=1)       = Sig("SinOsc.kr($(sc_arg(rate))).range($(sc_arg(low)), $(sc_arg(high)))")
lfo_saw(rate; low=-1, high=1)   = Sig("LFSaw.kr($(sc_arg(rate))).range($(sc_arg(low)), $(sc_arg(high)))")
lfo_tri(rate; low=-1, high=1)   = Sig("LFTri.kr($(sc_arg(rate))).range($(sc_arg(low)), $(sc_arg(high)))")
lfo_pulse(rate; low=0, high=1, width=0.5) =
    Sig("LFPulse.kr($(sc_arg(rate)), 0, $(sc_arg(width))).range($(sc_arg(low)), $(sc_arg(high)))")
lf_cub(rate; low=-1, high=1)    = Sig("LFCub.kr($(sc_arg(rate))).range($(sc_arg(low)), $(sc_arg(high)))")
lf_par(rate; low=-1, high=1)    = Sig("LFPar.kr($(sc_arg(rate))).range($(sc_arg(low)), $(sc_arg(high)))")

line(start, stop, dur)   = Sig("Line.kr($(sc_arg(start)), $(sc_arg(stop)), $(sc_arg(dur)))")
x_line(start, stop, dur) = Sig("XLine.kr($(sc_arg(start)), $(sc_arg(stop)), $(sc_arg(dur)))")
ramp_kr(input, lag)      = Sig("Ramp.kr($(sc_arg(input)), $(sc_arg(lag)))")
lag_kr(input, lag)       = Sig("Lag.kr($(sc_arg(input)), $(sc_arg(lag)))")
lag2_kr(input, lag)      = Sig("Lag2.kr($(sc_arg(input)), $(sc_arg(lag)))")
lag3_kr(input, lag)      = Sig("Lag3.kr($(sc_arg(input)), $(sc_arg(lag)))")

# ════════════════════════════════════════════════════════════════════
# Filters (pipe-curried)
# ════════════════════════════════════════════════════════════════════

low_pass(cutoff)             = (s::Sig) -> Sig("LPF.ar($(sc_arg(s)), $(sc_arg(cutoff)))")
high_pass(cutoff)            = (s::Sig) -> Sig("HPF.ar($(sc_arg(s)), $(sc_arg(cutoff)))")
band_pass(cutoff, q=0.5)     = (s::Sig) -> Sig("BPF.ar($(sc_arg(s)), $(sc_arg(cutoff)), $(sc_arg(q)))")
band_reject(cutoff, q=0.5)   = (s::Sig) -> Sig("BRF.ar($(sc_arg(s)), $(sc_arg(cutoff)), $(sc_arg(q)))")
rlpf(cutoff, q=0.5)          = (s::Sig) -> Sig("RLPF.ar($(sc_arg(s)), $(sc_arg(cutoff)), $(sc_arg(q)))")
rhpf(cutoff, q=0.5)          = (s::Sig) -> Sig("RHPF.ar($(sc_arg(s)), $(sc_arg(cutoff)), $(sc_arg(q)))")
moog_ff(cutoff, gain=2)      = (s::Sig) -> Sig("MoogFF.ar($(sc_arg(s)), $(sc_arg(cutoff)), $(sc_arg(gain)))")
leak_dc(coef=0.995)          = (s::Sig) -> Sig("LeakDC.ar($(sc_arg(s)), $(sc_arg(coef)))")
median(length=3)             = (s::Sig) -> Sig("Median.ar($(sc_arg(length)), $(sc_arg(s)))")
slope_kr()                   = (s::Sig) -> Sig("Slope.kr($(sc_arg(s)))")
b_low_pass(freq, rq=0.7)     = (s::Sig) -> Sig("BLowPass.ar($(sc_arg(s)), $(sc_arg(freq)), $(sc_arg(rq)))")
b_high_pass(freq, rq=0.7)    = (s::Sig) -> Sig("BHiPass.ar($(sc_arg(s)), $(sc_arg(freq)), $(sc_arg(rq)))")
b_peak_eq(freq, rq=0.7, db=0)  = (s::Sig) -> Sig("BPeakEQ.ar($(sc_arg(s)), $(sc_arg(freq)), $(sc_arg(rq)), $(sc_arg(db)))")
b_low_shelf(freq, rs=0.7, db=0)  = (s::Sig) -> Sig("BLowShelf.ar($(sc_arg(s)), $(sc_arg(freq)), $(sc_arg(rs)), $(sc_arg(db)))")
b_high_shelf(freq, rs=0.7, db=0) = (s::Sig) -> Sig("BHiShelf.ar($(sc_arg(s)), $(sc_arg(freq)), $(sc_arg(rs)), $(sc_arg(db)))")

# ════════════════════════════════════════════════════════════════════
# Delays / reverb
# ════════════════════════════════════════════════════════════════════

delay_n(time, max=1)     = (s::Sig) -> Sig("DelayN.ar($(sc_arg(s)), $(sc_arg(max)), $(sc_arg(time)))")
delay_l(time, max=1)     = (s::Sig) -> Sig("DelayL.ar($(sc_arg(s)), $(sc_arg(max)), $(sc_arg(time)))")
delay_c(time, max=1)     = (s::Sig) -> Sig("DelayC.ar($(sc_arg(s)), $(sc_arg(max)), $(sc_arg(time)))")
comb_n(time, decay, max=1) = (s::Sig) -> Sig("CombN.ar($(sc_arg(s)), $(sc_arg(max)), $(sc_arg(time)), $(sc_arg(decay)))")
comb_l(time, decay, max=1) = (s::Sig) -> Sig("CombL.ar($(sc_arg(s)), $(sc_arg(max)), $(sc_arg(time)), $(sc_arg(decay)))")
comb_c(time, decay, max=1) = (s::Sig) -> Sig("CombC.ar($(sc_arg(s)), $(sc_arg(max)), $(sc_arg(time)), $(sc_arg(decay)))")
allpass_n(time, decay, max=1) = (s::Sig) -> Sig("AllpassN.ar($(sc_arg(s)), $(sc_arg(max)), $(sc_arg(time)), $(sc_arg(decay)))")
allpass_l(time, decay, max=1) = (s::Sig) -> Sig("AllpassL.ar($(sc_arg(s)), $(sc_arg(max)), $(sc_arg(time)), $(sc_arg(decay)))")
allpass_c(time, decay, max=1) = (s::Sig) -> Sig("AllpassC.ar($(sc_arg(s)), $(sc_arg(max)), $(sc_arg(time)), $(sc_arg(decay)))")
free_verb(mix=0.33, room=0.5, damp=0.5) =
    (s::Sig) -> Sig("FreeVerb.ar($(sc_arg(s)), $(sc_arg(mix)), $(sc_arg(room)), $(sc_arg(damp)))")
g_verb(roomsize=10, revtime=3, damping=0.5, inbw=0.5, spread=15, drylevel=1, earlyref=0.7, taillevel=0.5) =
    (s::Sig) -> Sig("GVerb.ar($(sc_arg(s)), $(sc_arg(roomsize)), $(sc_arg(revtime)), $(sc_arg(damping)), $(sc_arg(inbw)), $(sc_arg(spread)), $(sc_arg(drylevel)), $(sc_arg(earlyref)), $(sc_arg(taillevel)))")
decay(time=1)           = (s::Sig) -> Sig("Decay.ar($(sc_arg(s)), $(sc_arg(time)))")
decay2(attack=0.01, release=1) = (s::Sig) -> Sig("Decay2.ar($(sc_arg(s)), $(sc_arg(attack)), $(sc_arg(release)))")

# ════════════════════════════════════════════════════════════════════
# Spatial
# ════════════════════════════════════════════════════════════════════

stereo_pan(pos=0, level=1)      = (s::Sig) -> Sig("Pan2.ar($(sc_arg(s)), $(sc_arg(pos)), $(sc_arg(level)))")
stereo_pan_lin(pos=0, level=1)  = (s::Sig) -> Sig("LinPan2.ar($(sc_arg(s)), $(sc_arg(pos)), $(sc_arg(level)))")
stereo_balance(other, pos=0, level=1) = (s::Sig) -> Sig("Balance2.ar($(sc_arg(s)), $(sc_arg(other)), $(sc_arg(pos)), $(sc_arg(level)))")
stereo_rotate(other, angle=0)   = (s::Sig) -> Sig("Rotate2.ar($(sc_arg(s)), $(sc_arg(other)), $(sc_arg(angle)))")
splay(spread=1, level=1)  = (s::Sig) -> Sig("Splay.ar($(sc_arg(s)), $(sc_arg(spread)), $(sc_arg(level)))")
mix_sigs(sigs::Vector{Sig}) = Sig("Mix.ar([" * join((s.code for s in sigs), ", ") * "])")

# ════════════════════════════════════════════════════════════════════
# Distortion / shaping
# ════════════════════════════════════════════════════════════════════

tanh_drive(amount=1)  = (s::Sig) -> Sig("(($(sc_arg(s))) * $(sc_arg(amount))).tanh")
soft_clip()           = (s::Sig) -> Sig("$(sc_arg(s)).softclip")
cubic()               = (s::Sig) -> Sig("$(sc_arg(s)).cubed")
clip(low=-1, high=1)  = (s::Sig) -> Sig("$(sc_arg(s)).clip($(sc_arg(low)), $(sc_arg(high)))")
fold(low=-1, high=1)  = (s::Sig) -> Sig("$(sc_arg(s)).fold($(sc_arg(low)), $(sc_arg(high)))")
wrap(low=-1, high=1)  = (s::Sig) -> Sig("$(sc_arg(s)).wrap($(sc_arg(low)), $(sc_arg(high)))")
decimator(rate=11025, bits=8) =
    (s::Sig) -> Sig("Decimator.ar($(sc_arg(s)), $(sc_arg(rate)), $(sc_arg(bits)))")

abs_sig()  = (s::Sig) -> Sig("$(sc_arg(s)).abs")
sqrt_sig() = (s::Sig) -> Sig("$(sc_arg(s)).sqrt")
pow_sig(p) = (s::Sig) -> Sig("$(sc_arg(s)).pow($(sc_arg(p)))")

# ════════════════════════════════════════════════════════════════════
# Envelopes (multiply into the signal chain)
# ════════════════════════════════════════════════════════════════════

env_perc(attack, release; level=1, curve=-4) = (s::Sig) ->
    Sig("($(sc_arg(s)) * EnvGen.kr(Env.perc($(sc_arg(attack)), $(sc_arg(release)), $(sc_arg(level)), $(sc_arg(curve))), doneAction: 2))")

env_linen(attack, sustain, release; level=1, curve=:lin) = (s::Sig) ->
    Sig("($(sc_arg(s)) * EnvGen.kr(Env.linen($(sc_arg(attack)), $(sc_arg(sustain)), $(sc_arg(release)), $(sc_arg(level)), $(sc_sym(curve))), doneAction: 2))")

env_adsr(attack, decay, sustain_level, release; gate=:gate, curve=-4, peak=1) = (s::Sig) ->
    Sig("($(sc_arg(s)) * EnvGen.kr(Env.adsr($(sc_arg(attack)), $(sc_arg(decay)), $(sc_arg(sustain_level)), $(sc_arg(release)), $(sc_arg(peak)), $(sc_arg(curve))), $(sc_arg(gate)), doneAction: 2))")

env_asr(attack, sustain_level, release; gate=:gate, curve=-4) = (s::Sig) ->
    Sig("($(sc_arg(s)) * EnvGen.kr(Env.asr($(sc_arg(attack)), $(sc_arg(sustain_level)), $(sc_arg(release)), $(sc_arg(curve))), $(sc_arg(gate)), doneAction: 2))")

env_cutoff(release; gate=:gate, curve=:lin) = (s::Sig) ->
    Sig("($(sc_arg(s)) * EnvGen.kr(Env.cutoff($(sc_arg(release)), 1, $(sc_sym(curve))), $(sc_arg(gate)), doneAction: 2))")

env_sine(dur=1, level=1) = (s::Sig) ->
    Sig("($(sc_arg(s)) * EnvGen.kr(Env.sine($(sc_arg(dur)), $(sc_arg(level))), doneAction: 2))")

env_dadsr(delay, attack, decay, sustain_level, release; gate=:gate, peak=1, curve=-4) = (s::Sig) ->
    Sig("($(sc_arg(s)) * EnvGen.kr(Env.dadsr($(sc_arg(delay)), $(sc_arg(attack)), $(sc_arg(decay)), $(sc_arg(sustain_level)), $(sc_arg(release)), $(sc_arg(peak)), $(sc_arg(curve))), $(sc_arg(gate)), doneAction: 2))")

env_pairs(times::AbstractVector, levels::AbstractVector; curve=:lin) = (s::Sig) ->
    Sig("($(sc_arg(s)) * EnvGen.kr(Env($(sc_arg(levels)), $(sc_arg(times)), $(sc_sym(curve))), doneAction: 2))")

# ════════════════════════════════════════════════════════════════════
# Triggers / pitch / utility
# ════════════════════════════════════════════════════════════════════

trig_kr(input, dur=0.1)  = Sig("Trig.kr($(sc_arg(input)), $(sc_arg(dur)))")
t_delay(input, delay)    = Sig("TDelay.kr($(sc_arg(input)), $(sc_arg(delay)))")
pitch_shift(window=0.2, pitch=1.0, pitch_disp=0, time_disp=0) =
    (s::Sig) -> Sig("PitchShift.ar($(sc_arg(s)), $(sc_arg(window)), $(sc_arg(pitch)), $(sc_arg(pitch_disp)), $(sc_arg(time_disp)))")
freq_shift(freq=0, phase=0) =
    (s::Sig) -> Sig("FreqShift.ar($(sc_arg(s)), $(sc_arg(freq)), $(sc_arg(phase)))")
vibrato_sig(rate=6, depth=0.02, delay=0.1, onset=0.0) =
    (s::Sig) -> Sig("Vibrato.ar($(sc_arg(s)), $(sc_arg(rate)), $(sc_arg(depth)), $(sc_arg(delay)), $(sc_arg(onset)))")

to_kr() = (s::Sig) -> Sig("A2K.kr($(sc_arg(s)))")
to_ar() = (s::Sig) -> Sig("K2A.ar($(sc_arg(s)))")

# Buffers
play_buf(channels::Int, buf, rate=1, trigger=1, start=0, loop=0, doneAction=0) =
    Sig("PlayBuf.ar($channels, $(sc_arg(buf)), $(sc_arg(rate)), $(sc_arg(trigger)), $(sc_arg(start)), $(sc_arg(loop)), $(sc_arg(doneAction)))")
buf_rd(channels::Int, buf, phase, loop=0, interp=2) =
    Sig("BufRd.ar($channels, $(sc_arg(buf)), $(sc_arg(phase)), $(sc_arg(loop)), $(sc_arg(interp)))")

# Demand / random
demand_seq(values::AbstractVector; repeats=:inf) =
    Sig("Dseq($(sc_arg(values)), $(sc_arg(repeats)))")
demand_white(low, high) =
    Sig("Dwhite($(sc_arg(low)), $(sc_arg(high)))")
t_rand(low, high, trig) =
    Sig("TRand.kr($(sc_arg(low)), $(sc_arg(high)), $(sc_arg(trig)))")

# ════════════════════════════════════════════════════════════════════
# Arithmetic
# ════════════════════════════════════════════════════════════════════

Base.:*(a::Sig, b::Sig)    = Sig("($(a.code) * $(b.code))")
Base.:*(a::Sig, b::Real)   = Sig("($(a.code) * $b)")
Base.:*(a::Real, b::Sig)   = Sig("($a * $(b.code))")
Base.:*(a::Sig, b::Symbol) = Sig("($(a.code) * $b)")
Base.:*(a::Symbol, b::Sig) = Sig("($a * $(b.code))")
Base.:+(a::Sig, b::Sig)    = Sig("($(a.code) + $(b.code))")
Base.:+(a::Sig, b::Real)   = Sig("($(a.code) + $b)")
Base.:+(a::Real, b::Sig)   = Sig("($a + $(b.code))")
Base.:+(a::Sig, b::Symbol) = Sig("($(a.code) + $b)")
Base.:+(a::Symbol, b::Sig) = Sig("($a + $(b.code))")
Base.:-(a::Sig, b::Sig)    = Sig("($(a.code) - $(b.code))")
Base.:-(a::Sig, b::Real)   = Sig("($(a.code) - $b)")
Base.:-(a::Real, b::Sig)   = Sig("($a - $(b.code))")
Base.:-(a::Sig)            = Sig("($(a.code).neg)")
Base.:/(a::Sig, b::Real)   = Sig("($(a.code) / $b)")
Base.:/(a::Sig, b::Sig)    = Sig("($(a.code) / $(b.code))")

amp(x)    = (s::Sig) -> s * x
offset(x) = (s::Sig) -> s + x

# Symbol arithmetic — so `:freq * 2` reads naturally inside a DSL
# expression. These didn't have methods before (Julia's Symbol doesn't
# define arithmetic), so this is purely additive — no surprise on
# existing call sites. Returns a Sig containing the literal SC code
# `freq * 2`, ready to be consumed by further DSL functions.
Base.:*(a::Symbol, b::Real)   = Sig("($a * $b)")
Base.:*(a::Real, b::Symbol)   = Sig("($a * $b)")
Base.:*(a::Symbol, b::Symbol) = Sig("($a * $b)")
Base.:+(a::Symbol, b::Real)   = Sig("($a + $b)")
Base.:+(a::Real, b::Symbol)   = Sig("($a + $b)")
Base.:+(a::Symbol, b::Symbol) = Sig("($a + $b)")
Base.:-(a::Symbol, b::Real)   = Sig("($a - $b)")
Base.:-(a::Real, b::Symbol)   = Sig("($a - $b)")
Base.:-(a::Symbol, b::Symbol) = Sig("($a - $b)")
Base.:/(a::Symbol, b::Real)   = Sig("($a / $b)")
Base.:/(a::Real, b::Symbol)   = Sig("($a / $b)")
Base.:/(a::Symbol, b::Symbol) = Sig("($a / $b)")

# Sig×Symbol pairs for the operators that weren't already defined
# above (only -, / are new; *, + were defined in the main arithmetic
# block).
Base.:-(a::Sig, b::Symbol) = Sig("($(a.code) - $b)")
Base.:-(a::Symbol, b::Sig) = Sig("($a - $(b.code))")
Base.:/(a::Sig, b::Symbol) = Sig("($(a.code) / $b)")
Base.:/(a::Symbol, b::Sig) = Sig("($a / $(b.code))")

# ════════════════════════════════════════════════════════════════════
# SynthDef builder with smart defaults
# ════════════════════════════════════════════════════════════════════

const _DEFAULT_PARAMS = (freq = 220, sustain = 0.5, gain = 0.5)

"""
    build_synth(name, sig; params, pan=0, auto_env=true, auto_gain=true)

Compile a `Sig` chain into a full SynthDef source string.

Smart defaults (override by passing `params=…` with the same keys):

  • `freq = 220`, `sustain = 0.5`, `gain = 0.5` are added if absent.
  • If `auto_env` is true and the chain doesn't already include an
    EnvGen call, we wrap the signal in an Env.linen so the synth
    self-frees after `sustain` seconds.
  • If `auto_gain` is true, we multiply the final signal by the
    `gain` arg so live pattern overrides of :gain take effect.

Output is always routed through OffsetOut + DirtPan so it slots
into the SuperDirt mix.
"""
function build_synth(name::Symbol, sig::Sig;
                     params::NamedTuple = NamedTuple(),
                     pan = 0,
                     auto_env::Bool = true,
                     auto_gain::Bool = true)
    # Merge default params in (user-provided keys win).
    merged = merge(_DEFAULT_PARAMS, params)

    code = sig.code
    # Auto-envelope only when the chain doesn't already have one.
    if auto_env && !occursin("EnvGen", code)
        code = "($code * EnvGen.kr(Env.linen(0.01, sustain, 0.1), doneAction: 2))"
    end
    # Auto-gain. Wrapped after the env so :gain scales the final
    # amplitude rather than just the pre-env carrier.
    if auto_gain && haskey(merged, :gain) && !occursin("gain", code)
        code = "($code * gain)"
    end

    param_parts = String["out", "pan = $(pan)"]
    for (k, v) in pairs(merged)
        push!(param_parts, "$k = $v")
    end
    param_decl = "|" * join(param_parts, ", ") * "|"
    body = "    OffsetOut.ar(out, DirtPan.ar($code, ~dirt.numChannels, pan));"
    "SynthDef(\\$name, { $param_decl\n$body\n}).add;\n"
end

"""
    synth_source(name, sig; kwargs...) -> String

Alias for build_synth — handier name when you just want to inspect
the generated SC without playing it.
"""
synth_source(args...; kwargs...) = build_synth(args...; kwargs...)

"""
    play_synth(name, sig; kwargs...) -> String

Compile via `build_synth`, send to SC via `/ressac/evalAndPlay`
(same path as T), and register the synth so :browse / :lib / pattern
lookups see it. Returns the generated source. Same kwargs as
build_synth.
"""
function play_synth(name::Symbol, sig::Sig; kwargs...)
    src = build_synth(name, sig; kwargs...)
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
    @synth name body
    @synth name (params) body
    @synth name (params,) (opts,) body

Sugar for play_synth. The simplest form auto-fills everything:

    @synth :mywob saw(:freq) |> rlpf(1200, 0.3)

With explicit params:

    @synth :acid (freq=80, cutoff=2000, envmod=4) saw(:freq) |> rlpf(:cutoff * (1 + :envmod), 0.3)

With opts (e.g. `auto_env=false` for drones):

    @synth :drone (freq=110, sustain=999) (auto_env=false,) saw(:freq) |> low_pass(800)
"""
macro synth(name, body)
    esc(:(play_synth($name, $body)))
end
macro synth(name, params, body)
    esc(:(play_synth($name, $body; params = $params)))
end
macro synth(name, params, opts, body)
    esc(:(play_synth($name, $body; params = $params, $opts...)))
end

end # module SynthDSL
