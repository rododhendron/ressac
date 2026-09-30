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

import ..Ressac: _LIVE_SCHEDULER, _INSTALLING_SYNTH, _AUDITION_ARGS, _DRONE_CAPTURE,
                 send_osc, encode, OSCMessage,
                 register_synth!, register_synth_alias!, SynthEntry

# Re-export the whole UGen surface so `using Ressac.SynthDSL` brings
# everything in scope at once.
export Sig, sc_arg, ugen
# Oscillators
export saw, sin_osc, pulse, tri, square, var_saw, blip, formant, klang
export impulse_ar, impulse_kr
# Noise
export white, pink, brown, gray, clip_noise, crackle, dust, dust2
export lf_noise0, lf_noise1, lf_noise2
# Chaotic / nonlinear sources (sc3-plugins)
export lorenz, henon, logistic, standard_map, latoo, lincong, quad, fbsine, gbman, cusp
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
export chorus, flanger, phaser
export grain_buf, warp1
# Spatial
export stereo_pan, stereo_pan_lin, stereo_balance, stereo_rotate, splay, mix_sigs
# Distortion / shaping
export tanh_drive, soft_clip, cubic, clip, fold, wrap, decimator, fold2, clip2, round_q, feedback
export midicps, cpsmidi, safe
export amp, offset, abs_sig, sqrt_sig, pow_sig
# Envelopes
export env_perc, env_linen, env_adsr, env_asr, env_cutoff, env_sine
export env_dadsr, env_pairs, env, env_gen
# Triggers / pitch
export trig_kr, t_delay, pitch_shift, freq_shift, vibrato_sig
# Rate conversion
export to_kr, to_ar
# Buffers
export play_buf, buf_rd
# Sequence helpers
export demand_seq, demand_white, t_rand
# Top-level builders
export build_synth, play_synth, @synth, synth_source, drone_def_name, build_drone_synth

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

# Ce qu'une étape `|>` accepte en entrée : un signal, mais aussi un
# nombre ou un contrôle (une constante est un signal en SC).
const SigLike = Union{Sig,Real,Symbol}

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

"""
    ugen(name::Symbol, args...; rate::Symbol = :ar) -> Sig
    x |> ugen(name::Symbol, args...; rate) -> Sig      (dans @synth : x en premier)

Escape hatch for any SuperCollider UGen that isn't wrapped explicitly.

Direct form:

    ugen(:Pluck, white(), 1, 0.5, 0.4, 0.95)
    # → Sig("Pluck.ar(WhiteNoise.ar, 1, 0.5, 0.4, 0.95)")

Piped form inside @synth (Elixir style, the signal first):

    white() |> ugen(:Pluck, 1, 0.5, 0.4, 0.95)
    # → Sig("Pluck.ar(WhiteNoise.ar, 1, 0.5, 0.4, 0.95)")

Pass `rate=:kr` for control-rate UGens.
"""
# Des noms du catalogue de génomes qui ne sont pas des classes SC mais
# des méthodes (`(x).softclip`) ou des constructeurs (`Env.perc(…)`) :
# `ugen(:Cubed, x)` — écrit par un export — doit rendre du SC valide.
const _UGEN_METHOD_FORMS = Dict{Symbol,String}(
    :Softclip => "softclip", :Cubed => "cubed", :Midicps => "midicps", :Cpsmidi => "cpsmidi",
    :Fold => "fold", :Wrap => "wrap", :Clip => "clip", :Tanh => "tanh", :Fold2 => "fold2",
    :Clip2 => "clip2", :Round => "round")
const _UGEN_ENV_FORMS = Dict{Symbol,String}(
    :EnvPerc => "perc", :EnvLinen => "linen", :EnvAsr => "asr", :EnvAdsr => "adsr")

function ugen(name::Symbol, args...; rate::Symbol = :ar)
    if haskey(_UGEN_METHOD_FORMS, name) && !isempty(args)
        rest = length(args) > 1 ? "(" * join(sc_arg.(args[2:end]), ", ") * ")" : ""
        return Sig(string("(", sc_arg(args[1]), ").", _UGEN_METHOD_FORMS[name], rest))
    end
    haskey(_UGEN_ENV_FORMS, name) && return Sig(string("Env.", _UGEN_ENV_FORMS[name], "(", join(sc_arg.(args), ", "), ")"))
    name === :Div && length(args) == 2 && return Sig(string("(", sc_arg(args[1]), " / ", sc_arg(args[2]), ")"))
    name === :Raw && return Sig("Silent.ar")
    Sig(string(name, ".", rate, "(", join(sc_arg.(args), ", "), ")"))
end


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
# Chaotic / nonlinear audio sources (from sc3-plugins)
# ════════════════════════════════════════════════════════════════════
# Drop into a SynthDef like an oscillator — output is in roughly
# [-1, 1] and can drive filters, envelopes, FM, etc. Each system has
# the linear-interpolation variant (–L) exposed under the unsuffixed
# name; for raw / hard-edged variants use `ugen(:LorenzN, …)` etc.
#
# The `freq` arg controls the iteration rate (samples / second) of
# the underlying ODE or map — pitched textures emerge near
# `SampleRate.ir`, drone/granular textures at lower rates.

"Lorenz attractor — 3D continuous, classic chaos. Outputs the x-axis."
lorenz(freq = 22050, s = 10, r = 28, b = 8/3, h = 0.05,
       xi = 0.1, yi = 0, zi = 0) =
    Sig(string("LorenzL.ar(",
               join((sc_arg(freq), sc_arg(s), sc_arg(r), sc_arg(b),
                     sc_arg(h), sc_arg(xi), sc_arg(yi), sc_arg(zi)), ", "),
               ")"))

"Hénon map — 2D discrete. Sharp, glitchy chaos."
henon(freq = 22050, a = 1.4, b = 0.3, x0 = 0, x1 = 0) =
    Sig(string("HenonL.ar(",
               join((sc_arg(freq), sc_arg(a), sc_arg(b),
                     sc_arg(x0), sc_arg(x1)), ", "),
               ")"))

"Logistic map. `paramA` ∈ [3.57, 4] is chaotic. (SC class is `Logistic`,
no L/N/C variants — the map is already discrete.)"
logistic(freq = 1000, paramA = 3.0, x0 = 0.5) =
    Sig(string("Logistic.ar(",
               join((sc_arg(paramA), sc_arg(freq), sc_arg(x0)), ", "),
               ")"))

"Chirikov standard map — `k` controls chaos amount."
standard_map(freq = 22050, k = 1.0, xi = 0.5, yi = 0) =
    Sig(string("StandardL.ar(",
               join((sc_arg(freq), sc_arg(k), sc_arg(xi), sc_arg(yi)), ", "),
               ")"))

"Latoocarfian — Pickover's 2D map. Very 'noisy buzz' sounding."
latoo(freq = 22050, a = 1.0, b = 3.0, c = 0.5, d = 0.5,
      xi = 0.5, yi = 0.5) =
    Sig(string("LatoocarfianL.ar(",
               join((sc_arg(freq), sc_arg(a), sc_arg(b), sc_arg(c),
                     sc_arg(d), sc_arg(xi), sc_arg(yi)), ", "),
               ")"))

"Linear congruential generator — granular, can be very pitched."
lincong(freq = 22050, a = 1.1, c = 0.13, m = 1.0, xi = 0) =
    Sig(string("LinCongL.ar(",
               join((sc_arg(freq), sc_arg(a), sc_arg(c),
                     sc_arg(m), sc_arg(xi)), ", "),
               ")"))

"Quadratic map — xn+1 = a·xn² + b·xn + c."
quad(freq = 22050, a = 1.0, b = -1.0, c = -0.75, xi = 0) =
    Sig(string("QuadL.ar(",
               join((sc_arg(freq), sc_arg(a), sc_arg(b),
                     sc_arg(c), sc_arg(xi)), ", "),
               ")"))

"Feedback sine with linear congruential phase increment."
fbsine(freq = 22050, im = 1.0, fb = 0.1, a = 1.1, c = 0.5,
       xi = 0.1, yi = 0.1) =
    Sig(string("FBSineL.ar(",
               join((sc_arg(freq), sc_arg(im), sc_arg(fb), sc_arg(a),
                     sc_arg(c), sc_arg(xi), sc_arg(yi)), ", "),
               ")"))

"Gingerbreadman map — area-preserving 2D map."
gbman(freq = 22050, xi = 1.2, yi = 2.1) =
    Sig(string("GbmanL.ar(",
               join((sc_arg(freq), sc_arg(xi), sc_arg(yi)), ", "),
               ")"))

"Cusp catastrophe map."
cusp(freq = 22050, a = 1.0, b = 1.9, xi = 0) =
    Sig(string("CuspL.ar(",
               join((sc_arg(freq), sc_arg(a), sc_arg(b), sc_arg(xi)), ", "),
               ")"))

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

low_pass(s::SigLike, cutoff) = Sig("LPF.ar($(sc_arg(s)), $(sc_arg(cutoff)))")
high_pass(s::SigLike, cutoff) = Sig("HPF.ar($(sc_arg(s)), $(sc_arg(cutoff)))")
band_pass(s::SigLike, cutoff, q=0.5) = Sig("BPF.ar($(sc_arg(s)), $(sc_arg(cutoff)), $(sc_arg(q)))")
band_reject(s::SigLike, cutoff, q=0.5) = Sig("BRF.ar($(sc_arg(s)), $(sc_arg(cutoff)), $(sc_arg(q)))")
rlpf(s::SigLike, cutoff, q=0.5) = Sig("RLPF.ar($(sc_arg(s)), $(sc_arg(cutoff)), $(sc_arg(q)))")
rhpf(s::SigLike, cutoff, q=0.5) = Sig("RHPF.ar($(sc_arg(s)), $(sc_arg(cutoff)), $(sc_arg(q)))")
moog_ff(s::SigLike, cutoff, gain=2) = Sig("MoogFF.ar($(sc_arg(s)), $(sc_arg(cutoff)), $(sc_arg(gain)))")
leak_dc(s::SigLike, coef=0.995) = Sig("LeakDC.ar($(sc_arg(s)), $(sc_arg(coef)))")
median(s::SigLike, length=3) = Sig("Median.ar($(sc_arg(length)), $(sc_arg(s)))")
slope_kr(s::SigLike) = Sig("Slope.kr($(sc_arg(s)))")
b_low_pass(s::SigLike, freq, rq=0.7) = Sig("BLowPass.ar($(sc_arg(s)), $(sc_arg(freq)), $(sc_arg(rq)))")
b_high_pass(s::SigLike, freq, rq=0.7) = Sig("BHiPass.ar($(sc_arg(s)), $(sc_arg(freq)), $(sc_arg(rq)))")
b_peak_eq(s::SigLike, freq, rq=0.7, db=0) = Sig("BPeakEQ.ar($(sc_arg(s)), $(sc_arg(freq)), $(sc_arg(rq)), $(sc_arg(db)))")
b_low_shelf(s::SigLike, freq, rs=0.7, db=0) = Sig("BLowShelf.ar($(sc_arg(s)), $(sc_arg(freq)), $(sc_arg(rs)), $(sc_arg(db)))")
b_high_shelf(s::SigLike, freq, rs=0.7, db=0) = Sig("BHiShelf.ar($(sc_arg(s)), $(sc_arg(freq)), $(sc_arg(rs)), $(sc_arg(db)))")

# ════════════════════════════════════════════════════════════════════
# Delays / reverb
# ════════════════════════════════════════════════════════════════════

delay_n(s::SigLike, time, max=1) = Sig("DelayN.ar($(sc_arg(s)), $(sc_arg(max)), $(sc_arg(time)))")
delay_l(s::SigLike, time, max=1) = Sig("DelayL.ar($(sc_arg(s)), $(sc_arg(max)), $(sc_arg(time)))")
delay_c(s::SigLike, time, max=1) = Sig("DelayC.ar($(sc_arg(s)), $(sc_arg(max)), $(sc_arg(time)))")
comb_n(s::SigLike, time, decay, max=1) = Sig("CombN.ar($(sc_arg(s)), $(sc_arg(max)), $(sc_arg(time)), $(sc_arg(decay)))")
comb_l(s::SigLike, time, decay, max=1) = Sig("CombL.ar($(sc_arg(s)), $(sc_arg(max)), $(sc_arg(time)), $(sc_arg(decay)))")
comb_c(s::SigLike, time, decay, max=1) = Sig("CombC.ar($(sc_arg(s)), $(sc_arg(max)), $(sc_arg(time)), $(sc_arg(decay)))")
allpass_n(s::SigLike, time, decay, max=1) = Sig("AllpassN.ar($(sc_arg(s)), $(sc_arg(max)), $(sc_arg(time)), $(sc_arg(decay)))")
allpass_l(s::SigLike, time, decay, max=1) = Sig("AllpassL.ar($(sc_arg(s)), $(sc_arg(max)), $(sc_arg(time)), $(sc_arg(decay)))")
allpass_c(s::SigLike, time, decay, max=1) = Sig("AllpassC.ar($(sc_arg(s)), $(sc_arg(max)), $(sc_arg(time)), $(sc_arg(decay)))")
free_verb(s::SigLike, mix=0.33, room=0.5, damp=0.5) = Sig("FreeVerb.ar($(sc_arg(s)), $(sc_arg(mix)), $(sc_arg(room)), $(sc_arg(damp)))")
g_verb(s::SigLike, roomsize=10, revtime=3, damping=0.5, inbw=0.5, spread=15, drylevel=1, earlyref=0.7, taillevel=0.5) = Sig("GVerb.ar($(sc_arg(s)), $(sc_arg(roomsize)), $(sc_arg(revtime)), $(sc_arg(damping)), $(sc_arg(inbw)), $(sc_arg(spread)), $(sc_arg(drylevel)), $(sc_arg(earlyref)), $(sc_arg(taillevel)))")
decay(s::SigLike, time=1) = Sig("Decay.ar($(sc_arg(s)), $(sc_arg(time)))")
decay2(s::SigLike, attack=0.01, release=1) = Sig("Decay2.ar($(sc_arg(s)), $(sc_arg(attack)), $(sc_arg(release)))")

# ── Modulated delay effects ──────────────────────────────────────
# chorus  : sum of input + LFO-modulated short delay copy (~10ms)
# flanger : short comb with feedback, LFO-swept (gives the "jet" tone)
# phaser  : 4-stage allpass with LFO sweep (subtle phase wobble)

"""
    chorus(rate=0.5, depth=0.002, mix=0.5)

Pipe-friendly chorus. `rate` Hz LFO sweeps the delay time around
~10ms ±depth. `mix` (0..1) is the wet/dry blend.
"""
chorus(s::SigLike, rate=0.5, depth=0.002, mix=0.5) = Sig(
    "(($(sc_arg(s)) * (1 - $(sc_arg(mix)))) + " *
    "DelayL.ar($(sc_arg(s)), 0.05, 0.01 + " *
    "SinOsc.kr($(sc_arg(rate))).range(0, $(sc_arg(depth)))) * $(sc_arg(mix)))")

"""
    flanger(rate=0.2, depth=0.005, feedback=0.3)

Short comb filter with LFO-swept delay around ~5ms. Higher
`feedback` (0..0.95) gives the metallic flange resonance.
"""
flanger(s::SigLike, rate=0.2, depth=0.005, feedback=0.3) = Sig(
    "CombC.ar($(sc_arg(s)), 0.05, 0.005 + " *
    "SinOsc.kr($(sc_arg(rate))).range(0, $(sc_arg(depth))), $(sc_arg(feedback)))")

"""
    phaser(rate=0.3, depth=800)

4-stage all-pass cascade with the same LFO-swept centre frequency.
A classic 70s phaser sound. `depth` is the swing of the centre
frequency around 800 Hz.
"""
phaser(s::SigLike, rate=0.3, depth=800) = Sig(
    "(0..3).inject($(sc_arg(s)), { |sig, i| " *
    "AllpassC.ar(sig, 0.005, " *
    "(SinOsc.kr($(sc_arg(rate)) * (1 + i*0.1)).range(200, 200 + $(sc_arg(depth))) * 1).reciprocal, " *
    "0)})")

# ── Granular ─────────────────────────────────────────────────────
# These take a buffer reference (use grain_buf to allocate, or
# pass a registered SuperDirt sample). Keep the surface minimal —
# users can stack them for more elaborate granular if they want.

"""
    grain_buf(buf, dur=0.05, rate=1, pos=0.5, interp=4, pan=0, max_grains=512)

GrainBuf wrapper — granular reading from a buffer. `pos` 0..1 of
buffer; `dur` per-grain duration; `rate` pitch scaling.
"""
grain_buf(buf, dur=0.05, rate=1, pos=0.5, interp=4, pan=0, max_grains=512) = Sig(
    "GrainBuf.ar(2, Impulse.kr(1/$(sc_arg(dur))), $(sc_arg(dur)), " *
    "$(sc_arg(buf)), $(sc_arg(rate)), $(sc_arg(pos)), $(sc_arg(interp)), " *
    "$(sc_arg(pan)), -1, $(sc_arg(max_grains)))")

"""
    warp1(buf, pointer=0.5, freq_scale=1, window_size=0.1, env_buf=-1,
          overlaps=4, rand_ramp=0.1, interp=4)

Time-stretching granular pitch-shift via Warp1. Independent control
of pointer (playback position) and freq_scale (pitch).
"""
warp1(buf, pointer=0.5, freq_scale=1, window_size=0.1, env_buf=-1,
      overlaps=4, rand_ramp=0.1, interp=4) = Sig(
    "Warp1.ar(2, $(sc_arg(buf)), $(sc_arg(pointer)), $(sc_arg(freq_scale)), " *
    "$(sc_arg(window_size)), $(sc_arg(env_buf)), $(sc_arg(overlaps)), " *
    "$(sc_arg(rand_ramp)), $(sc_arg(interp)))")

# ════════════════════════════════════════════════════════════════════
# Spatial
# ════════════════════════════════════════════════════════════════════

stereo_pan(s::SigLike, pos=0, level=1) = Sig("Pan2.ar($(sc_arg(s)), $(sc_arg(pos)), $(sc_arg(level)))")
stereo_pan_lin(s::SigLike, pos=0, level=1) = Sig("LinPan2.ar($(sc_arg(s)), $(sc_arg(pos)), $(sc_arg(level)))")
stereo_balance(s::SigLike, other, pos=0, level=1) = Sig("Balance2.ar($(sc_arg(s)), $(sc_arg(other)), $(sc_arg(pos)), $(sc_arg(level)))")
stereo_rotate(s::SigLike, other, angle=0) = Sig("Rotate2.ar($(sc_arg(s)), $(sc_arg(other)), $(sc_arg(angle)))")
splay(s::SigLike, spread=1, level=1) = Sig("Splay.ar($(sc_arg(s)), $(sc_arg(spread)), $(sc_arg(level)))")
mix_sigs(sigs::Vector{Sig}) = Sig("Mix.ar([" * join((s.code for s in sigs), ", ") * "])")

# ════════════════════════════════════════════════════════════════════
# Distortion / shaping
# ════════════════════════════════════════════════════════════════════

tanh_drive(s::SigLike, amount=1) = Sig("(($(sc_arg(s))) * $(sc_arg(amount))).tanh")
soft_clip(s::SigLike) = Sig("$(sc_arg(s)).softclip")
cubic(s::SigLike) = Sig("$(sc_arg(s)).cubed")
clip(s::SigLike, low=-1, high=1) = Sig("$(sc_arg(s)).clip($(sc_arg(low)), $(sc_arg(high)))")
fold(s::SigLike, low=-1, high=1) = Sig("$(sc_arg(s)).fold($(sc_arg(low)), $(sc_arg(high)))")
wrap(s::SigLike, low=-1, high=1) = Sig("$(sc_arg(s)).wrap($(sc_arg(low)), $(sc_arg(high)))")
decimator(s::SigLike, rate=11025, bits=8) = Sig("Decimator.ar($(sc_arg(s)), $(sc_arg(rate)), $(sc_arg(bits)))")

abs_sig(s::SigLike) = Sig("$(sc_arg(s)).abs")
sqrt_sig(s::SigLike) = Sig("$(sc_arg(s)).sqrt")
pow_sig(s::SigLike, p) = Sig("$(sc_arg(s)).pow($(sc_arg(p)))")

# Symmetric fold/clip + quantize (used by the explorer's clean DSL export).
fold2(s::SigLike, amount=1) = Sig("($(sc_arg(s))).fold2($(sc_arg(amount)))")
clip2(s::SigLike, amount=1) = Sig("($(sc_arg(s))).clip2($(sc_arg(amount)))")

# Conversions de hauteur : note MIDI ↔ fréquence (méthodes SC).
midicps(x) = Sig("($(sc_arg(x))).midicps")
cpsmidi(x) = Sig("($(sc_arg(x))).cpsmidi")

# `x |> ugen(:RLPF, 800, 0.3)` : la même chose pour un UGen sans wrapper.
ugen(s::Sig, name::Symbol, args...; rate::Symbol = :ar) = ugen(name, s, args...; rate = rate)
# Une constante en tête de pipe (`400.0 |> ugen(:AllpassC, …)`) : le rendu
# la passe en DC.ar si le slot est audio.
ugen(s::Real, name::Symbol, args...; rate::Symbol = :ar) = ugen(name, s, args...; rate = rate)

"""
    safe(level = 0.95) -> étape

La chaîne de sécurité de Ressac : Sanitize (pas de NaN), LeakDC (pas de
composante continue), Limiter. Les exports la mettent en bout de chaîne.
"""
safe(s::SigLike, level = 0.95) = Sig("Limiter.ar(LeakDC.ar(Sanitize.ar($(sc_arg(s)))), $(sc_arg(level)))")
round_q(s::SigLike, quant=0.1) = Sig("($(sc_arg(s))).round($(sc_arg(quant)))")

"""
    feedback(builder) -> Sig

Single-sample feedback loop. `builder` receives the feedback bus as a
`Sig` (read via `LocalIn.ar`) and returns the output `Sig`; that output
is written back to the bus (`LocalOut.ar`) before being emitted. The
side effect can't be expressed as a plain value, so we wrap the whole
thing in an inline SC function `{ … }.value` — but the body stays real
DSL, e.g.:

    feedback() do fb
        sig = saw(:freq) + (fb |> tanh_drive(0.5))
        rlpf(sig, 800, 0.3)
    end
"""
function feedback(builder::Function)
    out = builder(Sig("fb"))::Sig
    Sig(string("{ var fb = LocalIn.ar(1); var out = ", sc_arg(out),
               "; LocalOut.ar(out); out }.value"))
end

# ════════════════════════════════════════════════════════════════════
# Envelopes (multiply into the signal chain)
# ════════════════════════════════════════════════════════════════════

env_perc(s::SigLike, attack, release; level=1, curve=-4) =
    Sig("($(sc_arg(s)) * EnvGen.kr(Env.perc($(sc_arg(attack)), $(sc_arg(release)), $(sc_arg(level)), $(sc_arg(curve))), doneAction: 2))")

env_linen(s::SigLike, attack, sustain, release; level=1, curve=:lin) =
    Sig("($(sc_arg(s)) * EnvGen.kr(Env.linen($(sc_arg(attack)), $(sc_arg(sustain)), $(sc_arg(release)), $(sc_arg(level)), $(sc_sym(curve))), doneAction: 2))")

env_adsr(s::SigLike, attack, decay, sustain_level, release; gate=:gate, curve=-4, peak=1) =
    Sig("($(sc_arg(s)) * EnvGen.kr(Env.adsr($(sc_arg(attack)), $(sc_arg(decay)), $(sc_arg(sustain_level)), $(sc_arg(release)), $(sc_arg(peak)), $(sc_arg(curve))), $(sc_arg(gate)), doneAction: 2))")

env_asr(s::SigLike, attack, sustain_level, release; gate=:gate, curve=-4) =
    Sig("($(sc_arg(s)) * EnvGen.kr(Env.asr($(sc_arg(attack)), $(sc_arg(sustain_level)), $(sc_arg(release)), $(sc_arg(curve))), $(sc_arg(gate)), doneAction: 2))")

env_cutoff(s::SigLike, release; gate=:gate, curve=:lin) =
    Sig("($(sc_arg(s)) * EnvGen.kr(Env.cutoff($(sc_arg(release)), 1, $(sc_sym(curve))), $(sc_arg(gate)), doneAction: 2))")

env_sine(s::SigLike, dur=1, level=1) =
    Sig("($(sc_arg(s)) * EnvGen.kr(Env.sine($(sc_arg(dur)), $(sc_arg(level))), doneAction: 2))")

env_dadsr(s::SigLike, delay, attack, decay, sustain_level, release; gate=:gate, peak=1, curve=-4) =
    Sig("($(sc_arg(s)) * EnvGen.kr(Env.dadsr($(sc_arg(delay)), $(sc_arg(attack)), $(sc_arg(decay)), $(sc_arg(sustain_level)), $(sc_arg(release)), $(sc_arg(peak)), $(sc_arg(curve))), $(sc_arg(gate)), doneAction: 2))")

env_pairs(s::SigLike, times::AbstractVector, levels::AbstractVector; curve=:lin) =
    Sig("($(sc_arg(s)) * EnvGen.kr(Env($(sc_arg(levels)), $(sc_arg(times)), $(sc_sym(curve))), doneAction: 2))")

"""
    env(levels, times; curve=:lin, release_node=-99, loop_node=-99) -> Sig

Build a raw SC `Env(levels, times, curve, releaseNode, loopNode)`
envelope spec as a Sig. `levels` is a vector of breakpoint values
and `times` the durations between them (one fewer than `levels`).
Feed the result to `env_gen` for full EnvGen control, or use the
named `env_*` helpers for the common shapes.

```julia
e = env([0, 1, 0.3, 0], [0.01, 0.2, 0.5])
saw(:freq) |> env_gen(e; gate=:gate)
```
"""
env(levels::AbstractVector, times::AbstractVector; curve=:lin,
    release_node=-99, loop_node=-99) =
    Sig("Env($(sc_arg(levels)), $(sc_arg(times)), $(sc_sym(curve)), " *
        "$(sc_arg(release_node)), $(sc_arg(loop_node)))")

"""
    env_gen(envspec; gate=1, level_scale=1, level_bias=0, time_scale=1,
            done_action=2) -> (Sig -> Sig)

Raw `EnvGen.kr` wrapper. Unlike the curried `env_*` helpers (which
bake `doneAction: 2` and a fixed shape), `env_gen` exposes every
EnvGen argument:

  * `gate`        — re-trigger / hold input (use `:gate` for the
                    SuperDirt gate so the env releases on note-off)
  * `level_scale` — multiply the envelope output
  * `level_bias`  — add a constant offset to the output
  * `time_scale`  — stretch the whole envelope in time
  * `done_action` — what the synth does when the env finishes
                    (2 = free the synth; 0 = nothing)

`envspec` is a Sig holding an `Env` construction — build one with
`env(...)` or wrap a raw `Sig("Env.perc(0.01, 1)")`.

Multiplies the signal by the envelope: `saw(:freq) |> env_gen(my_env)`.
"""
function env_gen(s::SigLike, envspec; gate=1, level_scale=1, level_bias=0,
                 time_scale=1, done_action=2)
    return Sig("($(sc_arg(s)) * EnvGen.kr(" *
        "$(sc_arg(envspec)), $(sc_arg(gate)), $(sc_arg(level_scale)), " *
        "$(sc_arg(level_bias)), $(sc_arg(time_scale)), " *
        "doneAction: $(sc_arg(done_action))))")
end

# ════════════════════════════════════════════════════════════════════
# Triggers / pitch / utility
# ════════════════════════════════════════════════════════════════════

trig_kr(input, dur=0.1)  = Sig("Trig.kr($(sc_arg(input)), $(sc_arg(dur)))")
t_delay(input, delay)    = Sig("TDelay.kr($(sc_arg(input)), $(sc_arg(delay)))")
pitch_shift(s::SigLike, window=0.2, pitch=1.0, pitch_disp=0, time_disp=0) = Sig("PitchShift.ar($(sc_arg(s)), $(sc_arg(window)), $(sc_arg(pitch)), $(sc_arg(pitch_disp)), $(sc_arg(time_disp)))")
freq_shift(s::SigLike, freq=0, phase=0) = Sig("FreqShift.ar($(sc_arg(s)), $(sc_arg(freq)), $(sc_arg(phase)))")
vibrato_sig(s::SigLike, rate=6, depth=0.02, delay=0.1, onset=0.0) = Sig("Vibrato.ar($(sc_arg(s)), $(sc_arg(rate)), $(sc_arg(depth)), $(sc_arg(delay)), $(sc_arg(onset)))")

to_kr(s::SigLike) = Sig("A2K.kr($(sc_arg(s)))")
to_ar(s::SigLike) = Sig("K2A.ar($(sc_arg(s)))")

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

amp(s::Sig, x)    = s * x
offset(s::Sig, x) = s + x

# Make Sig scalar-broadcastable so `[:freq, :freq + 1] .+ sin_osc(35)`
# treats the Sig modulator as a single value to add to every channel,
# matching SC's multichannel expansion (`[a, b] + mod` adds the mod
# to each element). Without this, broadcast tries to iterate the Sig
# and crashes on `length`.
Base.broadcastable(s::Sig) = Ref(s)

"""
    chan(elems...) -> Sig

Multichannel expansion — emit an SC array `[a, b, c, …]` as a single
`Sig`. Each element can be a Sig, Symbol, Real, or any combination;
they get rendered via `sc_arg`. The returned Sig composes with the
normal arithmetic operators so `chan(:freq, :freq + 1) + 32` reads
naturally and produces `[freq, (freq + 1)] + 32` in SC — which SC
expands across channels.

```julia
sin_osc(chan(:freq, :freq + 1) + 32 + 33 * sin_osc(35))
# → SinOsc.ar([freq, (freq + 1)] + 32 + (33 * SinOsc.ar(35)))
```
"""
chan(elems...) = Sig("[" * join(sc_arg.(elems), ", ") * "]")
export chan

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

# Puissance et moins unaire : `sin_osc(:freq) ^ 2` (mise en forme),
# `:freq ^ 2`, `-saw(:freq)` (inversion de phase). SC a `**`.
Base.:^(a::Sig, b::Real)      = Sig("($(a.code) ** $b)")
Base.:^(a::Sig, b::Sig)       = Sig("($(a.code) ** $(b.code))")
Base.:^(a::Symbol, b::Real)   = Sig("($a ** $b)")
Base.:^(a::Real, b::Sig)      = Sig("($a ** $(b.code))")
Base.:^(a::Real, b::Symbol)   = Sig("($a ** $b)")
Base.:-(a::Symbol)            = Sig("($a.neg)")

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
    effective_params(params) -> NamedTuple

Les arguments que le SynthDef aura vraiment : ceux déclarés plus les
défauts ajoutés par `build_synth` (`freq`, `sustain`, `gain`), moins les
options de compilation (`auto_env`, `auto_gain`, `pan`). C'est cette
liste qui dit à Ressac qu'un synth répond à `n` / `note` et que sa durée
peut suivre l'événement.
"""
function effective_params(params::NamedTuple)
    declared = NamedTuple()
    for (k, v) in pairs(params)
        k in (:auto_env, :auto_gain, :pan) && continue
        declared = merge(declared, NamedTuple{(k,)}((v,)))
    end
    return merge(_DEFAULT_PARAMS, declared)
end

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
                     auto_gain::Bool = true,
                     gate::Bool = false)
    # SynthDef args in SuperCollider must be numeric — `false` / `true`
    # as a default value throws DoesNotUnderstandError. So if the user
    # wrote `(freq=110, auto_env=false)` as a single tuple (which is the
    # natural typing flow), pull build-time options out of `params`
    # BEFORE we emit them as SynthDef args.
    local_params = NamedTuple()
    for (k, v) in pairs(params)
        if k === :auto_env
            auto_env = v isa Bool ? v : auto_env
        elseif k === :auto_gain
            auto_gain = v isa Bool ? v : auto_gain
        elseif k === :pan
            pan = v
        else
            local_params = merge(local_params, NamedTuple{(k,)}((v,)))
        end
    end
    # Merge default params in (user-provided keys win).
    merged = merge(_DEFAULT_PARAMS, local_params)

    code = sig.code
    if gate
        # Variante drone : le nœud tient tant que `gate` vaut 1 et se
        # libère sur `release` secondes après gate 0. Une enveloppe écrite
        # à la main garde sa forme mais ne libère plus le nœud (c'est la
        # porte qui s'en charge), sinon un `sustain` de 0.5 s tuerait le
        # drone avant qu'on ait touché un knob.
        code = replace(code, r"doneAction:\s*2" => "doneAction: 0")
        code = "($code * EnvGen.kr(Env.asr(0.01, 1, release), gate, doneAction: 2))"
        haskey(merged, :gate) || (merged = merge(merged, (gate = 1,)))
        haskey(merged, :release) || (merged = merge(merged, (release = 0.1,)))
    elseif auto_env && !occursin("EnvGen", code)
        # Auto-envelope only when the chain doesn't already have one.
        code = "($code * EnvGen.kr(Env.linen(0.01, sustain, 0.1), doneAction: 2))"
    end
    # Auto-gain. Wrapped after the env so :gain scales the final
    # amplitude rather than just the pre-env carrier. The match is
    # word-bounded so a user identifier containing the substring
    # (e.g. `gain_factor`, `pre_gain_amount`) doesn't suppress the
    # auto-multiply.
    if auto_gain && haskey(merged, :gain) && !occursin(r"\bgain\b", code)
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
    drone_def_name(name) -> Symbol

Nom SC de la variante à porte d'un synth : `:acid` → `:acid_drone`.
"""
drone_def_name(name::Symbol) = Symbol(name, "_drone")

"""
    build_drone_synth(name, sig; kwargs...) -> String

La variante drone d'un synth (`build_synth(…; gate = true)`) sous le nom
`drone_def_name(name)` : même chaîne, tenue par `gate`, relâchée en
`release` secondes.
"""
build_drone_synth(name::Symbol, sig::Sig; kwargs...) =
    build_synth(drone_def_name(name), sig; gate = true, kwargs...)

"""
    synth_source(name, sig; kwargs...) -> String

Alias for build_synth — handier name when you just want to inspect
the generated SC without playing it.
"""
synth_source(args...; kwargs...) = build_synth(args...; kwargs...)

"""
    play_synth(sc_name, sig; alias=nothing, kwargs...) -> String

Compile via `build_synth`, send to SC via `/ressac/evalAndPlay`
(same path as T), and register the synth so :browse / :lib / pattern
lookups see it.

`sc_name` is the SynthDef name shipped to SuperCollider — typically
derived from the source filename so the file-on-disk and the SC
identifier are aligned.

`alias` (optional) is the short name the user types in patterns
(`p"alias"` or `:alias |> gate(...)`). The scheduler resolves alias
→ sc_name before shipping. Pass `nothing` (the default) to skip
aliasing; the user will type the sc_name directly. Aliases are
collision-checked: re-binding an existing alias to a different
sc_name logs an error and is refused (call `unregister_synth_alias!`
first).

Returns the generated SC source. Same kwargs as build_synth.
"""
# Une étape curried (`clip(0.5)`, `low_pass(800)`) arrivée là sans signal :
# le corps s'est terminé sur `|> f` au lieu de `|> f(…)`, ou sur `f(…)`
# seul. On le dit, plutôt qu'une MethodError sur play_synth.
play_synth(sc_name::Symbol, f::Function; kwargs...) =
    throw(ArgumentError("le synth :$sc_name ne se termine pas sur un signal mais sur une étape sans entrée — " *
                        "écris `saw(:freq) |> nom(…)` (le signal d'abord, puis l'étape entre parenthèses)"))

function play_synth(sc_name::Symbol, sig::Sig;
                    alias::Union{Symbol,Nothing} = nothing, kwargs...)
    src = build_synth(sc_name, sig; kwargs...)
    kw = Dict{Symbol,Any}(kwargs)
    declared = get(kw, :params, NamedTuple())
    eff = effective_params(declared)
    cap = _DRONE_CAPTURE[]
    if cap isa Vector
        # L'éditeur veut un drone : on ne joue rien, on lui rend la variante
        # à porte et les paramètres qu'il pourra moduler.
        push!(cap, (sc_name, build_drone_synth(sc_name, sig; kwargs...), eff))
        _register_dsl_synth!(sc_name, eff, alias)
        return src
    end
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return src
    # When _INSTALLING_SYNTH is true (set by the plugin loader during
    # Base.include of a .jl synth file), ship the install-only OSC.
    # Otherwise we're in the interactive `T` / `:test` path and want
    # SC to both register the SynthDef AND fire it once. Without this
    # split, plugin-loaded synths played a one-shot every session boot.
    if _INSTALLING_SYNTH[]
        send_osc(sched.osc, encode(OSCMessage("/dirt/evalSC", Any[src])))
        # Le jumeau à porte aussi, pour que PLAY puisse tenir ce synth en
        # drone sans repasser par l'éditeur.
        send_osc(sched.osc, encode(OSCMessage("/dirt/evalSC",
                                              Any[build_drone_synth(sc_name, sig; kwargs...)])))
    else
        send_osc(sched.osc,
                 encode(OSCMessage("/ressac/evalAndPlay",
                                    Any[String(sc_name), src, _AUDITION_ARGS[]...])))
    end
    _register_dsl_synth!(sc_name, eff, alias)
    src
end

function _register_dsl_synth!(sc_name::Symbol, eff::NamedTuple, alias)
    register_synth!(SynthEntry(sc_name, "user-dsl",
                               Dict{String,Any}("description" => "DSL-defined",
                                                "tags" => ["dsl"],
                                                "params" => Dict{String,Any}(String(k) => v for (k, v) in pairs(eff)
                                                                             if v isa Real))))
    alias !== nothing && register_synth_alias!(alias, sc_name)
    return nothing
end

"""
    _sc_name_from_source(file) -> Symbol

Resolve the SC SynthDef name from the macro's source-file path.
Used by `@synth` when no explicit alias is given: the file basename
(minus extension) becomes the name shipped to SuperCollider. Errors
if `file` doesn't point to a real file (REPL, eval'd string) — the
user must provide an explicit alias in that case.
"""
function _sc_name_from_source(file::AbstractString)
    isfile(file) || error("@synth: no source file context — provide an alias: `@synth :name body`")
    return Symbol(splitext(basename(file))[1])
end

"""
    _sc_name_for_aliased(file, alias) -> Symbol

When the user writes `@synth :alias body`, decide the SC SynthDef
name. In a real file, the SC name is the filename (so renaming the
file renames the SynthDef without touching the macro). In a REPL /
no-file context, the alias IS the SC name (there's nothing else to
use).
"""
function _sc_name_for_aliased(file::AbstractString, alias::Symbol)
    return isfile(file) ? Symbol(splitext(basename(file))[1]) : alias
end

"""
    @synth body
    @synth (params) body
    @synth (params,) (opts,) body
    @synth :alias body
    @synth :alias (params) body
    @synth :alias (params,) (opts,) body

Build a SynthDef from a DSL expression and ship it to SuperCollider.
Two layers of naming:

  * **SC SynthDef name** — the identifier SuperCollider knows the
    synth by. Derived from the source filename (minus extension) so
    `plugins/user-synths/wob1.jl` always ships as `\\wob1`. Rename
    the file = rename the SynthDef.
  * **Alias** (optional) — a short name the user types in patterns
    (`p"alias"` / `:alias |> gate(...)`). The scheduler resolves
    alias → SC name before sending. Skip the leading `:alias` to
    use the SC name directly.

Minimal: alias inferred, file-based SC name.

    # in plugins/user-synths/wob1.jl
    @synth saw(:freq) |> rlpf(1200, 0.3)
    # → SC \\wob1, no alias; pattern: p"wob1"

With short alias:

    @synth :wob saw(:freq) |> rlpf(1200, 0.3)
    # → SC \\wob1, alias `wob`; pattern: p"wob" or p"wob1"

With params + opts (any combo):

    @synth :acid (freq=80, cutoff=2000) saw(:freq) |> rlpf(:cutoff, 0.3)
    @synth :drone (freq=110, sustain=999) (auto_env=false,) saw(:freq) |> low_pass(800)

REPL / no-file context: an alias is required and becomes the SC
name (no filename to fall back on).
"""
# A single `(key=val)` without a trailing comma parses as a bare
# assignment Expr, not a NamedTuple — splatting it later throws a
# BoundsError. Wrap such bare assignments into a 1-tuple so both
# `(auto_env=false)` and `(auto_env=false,)` work the same. Already-
# tuple forms and everything else pass through unchanged.
function _normalize_kw_group(ex)
    if ex isa Expr && ex.head === :(=)
        return Expr(:tuple, ex)
    end
    return ex
end

"""
    _dsl_preprocess(src) -> String

Normalize a DSL source string before `Meta.parse` so a chain can put
the pipe operator at the START of a continuation line. Julia only
continues an expression onto the next line when the PREVIOUS line is
syntactically incomplete, so a leading `|>` would be an orphan parse
error. We join any `\\n<whitespace>|>` back onto the previous line.

    sin_osc(:freq)
      |> rlpf(800)        # ← leading pipe, joined to the line above
      |> tanh_drive(3)

Only `|>` is handled — it's unambiguously binary, so joining is
always correct. Other operators (`-`, `+`) can be unary at line
start, so we leave them alone.
"""
_dsl_preprocess(src::AbstractString) =
    replace(String(src), r"\n[ \t]*\|>" => " |>")

"""
    _dsl_parse_all(src) -> Expr

Analyse TOUT un fichier de synth, pas seulement sa première expression.
`Meta.parse` s'arrête après la première et lève « extra token after end
of expression » dès qu'un fichier contient un commentaire final suivi
d'une autre ligne, une variable, ou deux `@synth`. On renvoie un bloc
`:toplevel` évaluable tel quel par `Core.eval`.
"""
_dsl_parse_all(src::AbstractString) = Meta.parseall(_dsl_preprocess(src))

"""
    _dsl_synth_expr(src) -> Union{Nothing,Expr}

La première expression `@synth …` d'un fichier, ou `nothing`. Les autres
expressions (commentaires, variables d'aide) sont ignorées.
"""
function _dsl_synth_expr(src::AbstractString)
    top = try _dsl_parse_all(src) catch; return nothing end
    for ex in top.args
        ex isa Expr || continue
        ex.head === :macrocall && !isempty(ex.args) && string(ex.args[1]) == "@synth" && return ex
    end
    return nothing
end

# ── Le `|>` d'Elixir dans @synth ────────────────────────────────────
# `x |> f(a, b)` devient `f(x, a, b)` : la valeur de gauche est le premier
# argument. Les fonctions du DSL sont écrites ainsi (le signal d'abord),
# et n'importe quelle fonction dont le premier argument est un signal se
# pipe — les tiennes, `ugen(:Nom, …)`. `_` choisit la place
# (`x |> f(a, _)`), une fonction nue se pipe (`x |> soft_clip`), les
# mots-clés restent. Seul `@synth` réécrit : hors de lui, `|>` est celui
# de Julia et on écrit `rlpf(x, 800, 0.3)`.
# `_` ou `&1` dans le pipe : la valeur pipée, là où on la met.
_is_hole(a) = a === :_ || (a isa Expr && a.head === :& && length(a.args) == 1 && a.args[1] == 1)
_has_placeholder(args) = any(_is_hole, args)
_fill_placeholder(args, lhs) = [_is_hole(a) ? lhs : a for a in args]

# La capture d'Elixir : `&rlpf(&1, 800, 0.3)` est la fonction `x -> rlpf(x,
# 800, 0.3)`, `&(&1 + &2)` prend deux arguments. Utile pour nommer une
# étape (`drive = &tanh_drive(&1, 2)`, puis `x |> drive`).
_capture_index(a) = (a isa Expr && a.head === :& && length(a.args) == 1 && a.args[1] isa Integer) ? Int(a.args[1]) : 0
function _capture_max(ex)
    k = _capture_index(ex)
    k > 0 && return k
    ex isa Expr || return 0
    ex.head === :& && return 0                     # une capture imbriquée a ses propres &k
    return maximum((_capture_max(a) for a in ex.args); init = 0)
end
function _capture_fill(ex, syms)
    k = _capture_index(ex)
    k > 0 && return syms[k]
    ex isa Expr || return ex
    return Expr(ex.head, map(a -> _capture_fill(a, syms), ex.args)...)
end
function _elixir_capture(ex)
    n = _capture_max(ex.args[1])
    n == 0 && return ex
    syms = [gensym("cap$k") for k in 1:n]
    body = _capture_fill(ex.args[1], syms)
    return Expr(:->, Expr(:tuple, syms...), body)
end

function _elixir_pipes(ex)
    ex isa Expr || return ex
    if ex.head === :& && length(ex.args) == 1 && !(ex.args[1] isa Integer)
        return _elixir_capture(_elixir_pipes(ex.args[1]) |> x -> Expr(:&, x))
    end
    if ex.head === :call && length(ex.args) == 3 && ex.args[1] === :.|>
        # Pipe diffusé : `[a, b] .|> f(x)` → `f.(lhs, x)` — chaque canal
        # entre en premier argument.
        lhs = _elixir_pipes(ex.args[2]); rhs = _elixir_pipes(ex.args[3])
        if rhs isa Symbol || (rhs isa Expr && rhs.head === :. && length(rhs.args) == 2)
            return Expr(:., rhs, Expr(:tuple, lhs))
        elseif rhs isa Expr && rhs.head === :call
            f = rhs.args[1]
            params = length(rhs.args) >= 2 && rhs.args[2] isa Expr && rhs.args[2].head === :parameters ? rhs.args[2] : nothing
            rest = params === nothing ? rhs.args[2:end] : rhs.args[3:end]
            rest = _has_placeholder(rest) ? _fill_placeholder(rest, lhs) : vcat(Any[lhs], rest)
            return params === nothing ? Expr(:., f, Expr(:tuple, rest...)) :
                                        Expr(:., f, Expr(:tuple, params, rest...))
        end
        return Expr(:call, :.|>, lhs, rhs)
    end
    if ex.head === :call && length(ex.args) == 3 && ex.args[1] === :|>
        lhs = _elixir_pipes(ex.args[2])
        rhs = _elixir_pipes(ex.args[3])
        if rhs isa Symbol || (rhs isa Expr && rhs.head === :. && length(rhs.args) == 2)
            return Expr(:call, rhs, lhs)
        elseif rhs isa Expr && rhs.head === :call
            f = rhs.args[1]
            params = length(rhs.args) >= 2 && rhs.args[2] isa Expr && rhs.args[2].head === :parameters ? rhs.args[2] : nothing
            rest = params === nothing ? rhs.args[2:end] : rhs.args[3:end]
            rest = _has_placeholder(rest) ? _fill_placeholder(rest, lhs) : vcat(Any[lhs], rest)
            return params === nothing ? Expr(:call, f, rest...) : Expr(:call, f, params, rest...)
        end
        return Expr(:call, :|>, lhs, rhs)                # une fermeture, une variable : Julia
    end
    ex.head in (:quote, :macrocall) && return ex
    return Expr(ex.head, map(_elixir_pipes, ex.args)...)
end

macro synth(args...)
    isempty(args) && return :(error("@synth: needs a body"))
    body = _elixir_pipes(args[end])
    rest = args[1:end-1]
    # If the first arg is a QuoteNode (`:alias`) it's the alias.
    # Otherwise we're in the file-derived form.
    alias_expr, middle = if !isempty(rest) && rest[1] isa QuoteNode
        (rest[1], rest[2:end])
    else
        (nothing, rest)
    end
    params = length(middle) >= 1 ? _normalize_kw_group(middle[1]) : :(NamedTuple())
    opts   = length(middle) >= 2 ? _normalize_kw_group(middle[2]) : nothing
    # `__source__` is only bound inside the macro body. Capture its
    # `.file` here at expansion time and embed as a string literal in
    # the produced expression — referencing `__source__` from inside
    # the expansion is a NameError at call site.
    source_file = String(__source__.file)
    # GlobalRef bypasses call-site name lookup so the macro works when
    # expanded outside SynthDSL (e.g. from Main during a `:synth foo`
    # preview, where `_sc_name_for_aliased` would not be in scope).
    name_expr = alias_expr === nothing ?
        Expr(:call, GlobalRef(@__MODULE__, :_sc_name_from_source), source_file) :
        Expr(:call, GlobalRef(@__MODULE__, :_sc_name_for_aliased),
             source_file, alias_expr)
    play_fn = GlobalRef(@__MODULE__, :play_synth)
    call = if opts === nothing
        :($play_fn($name_expr, $body; params = $params, alias = $alias_expr))
    else
        :($play_fn($name_expr, $body; params = $params, alias = $alias_expr, $opts...))
    end
    return esc(call)
end

end # module SynthDSL
