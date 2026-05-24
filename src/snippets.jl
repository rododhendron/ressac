# Snippets — multi-line code templates the user can insert at the
# cursor. Browsable via :snip (alias :snippets) with j/k nav, `/`
# search, Space to preview (shows full body in the log), Enter to
# insert. Context-aware: the picker hides snippets that don't make
# sense in the current pane (patterns vs synth), unless their context
# is :any.

struct _Snippet
    trigger::String       # short name shown in the picker
    context::Symbol       # :patterns | :synth | :any
    category::String      # "rhythm" / "fx" / "envelope" / ...
    description::String   # one-line summary
    body::String          # text to insert (multi-line OK)
end

const _SNIPPETS = _Snippet[
    # ── Patterns: rhythm starting points ────────────────────────────
    _Snippet("kick4", :patterns, "rhythm",
        "Four-on-the-floor kick — the most fundamental house beat.", raw"""
        @d1 p"bd bd bd bd"
        """),
    _Snippet("kickhat", :patterns, "rhythm",
        "Kick on 1+3, hat on every step. Foundational house pattern.", raw"""
        @d1 p"bd ~ bd ~"
        @d2 p"hh hh hh hh"
        """),
    _Snippet("breakbeat", :patterns, "rhythm",
        "Classic break: kick on the 1, snare on the 3, ghost notes between.", raw"""
        @d1 p"bd ~ sn bd*2 ~ sn ~ bd"
        @d2 p"hh hh oh hh hh hh oh hh"
        """),
    _Snippet("polyrhythm", :patterns, "rhythm",
        "3-against-4 polyrhythm — kick triplets vs hat quads.", raw"""
        @d1 p"bd*3" |> gain(0.8)
        @d2 p"hh*4" |> gain(0.4)
        """),
    _Snippet("euclid", :patterns, "rhythm",
        "Euclidean rhythm. (k,n) = k beats spread evenly over n steps.", raw"""
        @d1 p"bd(3,8)"
        @d2 p"hh(7,16)" |> gain(0.5)
        """),
    _Snippet("tribal", :patterns, "rhythm",
        "Tribal-style polyrhythm with rest accents.", raw"""
        @d1 p"bd ~ ~ bd ~ bd ~ ~"
        @d2 p"~ ~ cp ~ ~ ~ cp ~"
        @d3 p"hh*8" |> gain(0.3)
        """),

    # ── Patterns: melody / bass ─────────────────────────────────────
    _Snippet("acidline", :patterns, "melody",
        "TB-303-style 16th-note acid line. Edit the n() sequence.", raw"""
        @d1 :acid303 |> n(p"0 3 5 7 3 5 0 7 5 3 5 7 0 3 5 7") |> gain(0.6)
        """),
    _Snippet("subline", :patterns, "melody",
        "Slow sub bass on the off-beats. Pair with a busy kick.", raw"""
        @d1 :subdrop |> n(p"0 3 5 0") |> gain(0.7)
        """),
    _Snippet("arp", :patterns, "melody",
        "Fast triadic arpeggio — root, 3rd, 5th, octave.", raw"""
        @d1 :arpdriver |> n(p"0 4 7 12 0 4 7 12") |> gain(0.55)
        """),
    _Snippet("chord_stab", :patterns, "melody",
        "Off-beat lofi chord stabs.", raw"""
        @d1 p"~ chordstab ~ chordstab" |> gain(0.6)
        """),
    _Snippet("pad_drone", :patterns, "melody",
        "Long sustained pad drone. cps slow → notes blend.", raw"""
        @d1 :softpad |> n(p"<0 5 7 3>") |> gain(0.4)
        """),
    _Snippet("wobble", :patterns, "melody",
        "Wobble bass with LFO rate riding the bar.", raw"""
        @d1 :rezzbass |> n(p"0 0 5 0 3 0 5 0") |> set(:rate, 4) |> gain(0.6)
        """),

    # ── Patterns: effect chains ─────────────────────────────────────
    _Snippet("fx_dub", :patterns, "fx",
        "Dub-style delay + room — append to any pattern line.", raw"""
         |> delay(0.5) |> delaytime(0.375) |> delayfeedback(0.6) |> room(0.7)
        """),
    _Snippet("fx_lpf", :patterns, "fx",
        "Low-pass with resonance — for filter sweeps.", raw"""
         |> lpf(p"<300 800 2000 6000>") |> resonance(0.4)
        """),
    _Snippet("fx_pan", :patterns, "fx",
        "Auto-pan over the bar via the time-pattern <…>.", raw"""
         |> pan(p"<0 0.5 1 0.5>")
        """),
    _Snippet("fx_drive", :patterns, "fx",
        "Hard saturation via SuperDirt's shape.", raw"""
         |> shape(0.8)
        """),

    # ── Patterns: full track skeletons ──────────────────────────────
    _Snippet("track_dnb", :patterns, "track",
        "Drum & bass skeleton — fast break + sub on 1.", raw"""
        cps!(0.46)
        @d1 p"bd ~ ~ ~ ~ ~ sn ~ ~ ~ bd ~ ~ ~ sn ~"
        @d2 p"hh*16" |> gain(0.4)
        @d3 :subdrop |> n(p"0 ~ ~ ~ 0 ~ 5 ~") |> gain(0.7)
        """),
    _Snippet("track_house", :patterns, "track",
        "Four-on-the-floor house template.", raw"""
        cps!(0.5)
        @d1 p"bd bd bd bd"
        @d2 p"~ cp ~ cp"
        @d3 p"hh*16" |> gain(0.35)
        @d4 :acid303 |> n(p"0 3 5 7") |> gain(0.45)
        """),
    _Snippet("track_dark", :patterns, "track",
        "Darksynth template — slow tempo, gated bass, pad.", raw"""
        cps!(0.42)
        @d1 :kickbrut |> n(p"0 ~ ~ 0 ~ ~ ~ 0") |> gain(0.8)
        @d2 :snareclap |> n(p"~ ~ 0 ~ ~ ~ 0 ~") |> gain(0.7)
        @d3 :gatedbass |> n(p"0 ~ 0 ~ 5 ~ 7 ~") |> gain(0.6)
        @d4 :darkpad |> n(p"<0 0 -2 -4>") |> gain(0.4)
        """),

    # ── Patterns: genre-specific rhythm templates ───────────────────
    _Snippet("jersey", :patterns, "genre",
        "Jersey club — bed-creak bounce, 5-on-the-floor kick, triplet hats.", raw"""
        cps!(0.58)
        @d1 p"bd ~ ~ bd bd ~ ~ bd"
        @d2 p"~ ~ cp ~ ~ ~ cp ~"
        @d3 p"[hh hh hh]*4" |> gain(0.35)
        """),

    _Snippet("footwork", :patterns, "genre",
        "Footwork — 160 BPM, fast hihats, sparse kicks, syncopated claps.", raw"""
        cps!(0.66)
        @d1 p"bd ~ ~ ~ ~ bd ~ ~ ~ ~ ~ ~ ~ bd ~ ~"
        @d2 p"~ ~ ~ ~ cp ~ ~ ~ ~ ~ ~ ~ cp ~ ~ ~"
        @d3 p"hh*16" |> gain(0.4)
        @d4 p"~ ~ sn*3 ~ ~ ~ sn ~ ~ sn*2 ~ ~ ~ ~" |> gain(0.5)
        """),

    _Snippet("garage", :patterns, "genre",
        "UK garage / 2-step — broken kick, off-beat hats, swung snare.", raw"""
        cps!(0.55)
        @d1 p"bd ~ ~ bd ~ ~ bd ~"
        @d2 p"~ ~ cp ~ ~ ~ ~ cp"
        @d3 p"~ hh ~ hh ~ hh ~ hh" |> gain(0.4)
        """),

    _Snippet("trap", :patterns, "genre",
        "Trap — rolling hi-hats with triplet bursts + 808 kick.", raw"""
        cps!(0.45)
        @d1 p"bd ~ ~ ~ ~ ~ bd ~"
        @d2 p"~ ~ cp ~ ~ ~ cp ~"
        @d3 p"hh hh [hh hh hh] hh hh [hh hh hh] hh hh" |> gain(0.4)
        @d4 :subdrop |> n(p"0 ~ ~ 0 ~ ~ 5 ~") |> gain(0.6)
        """),

    _Snippet("dnb", :patterns, "genre",
        "Drum & bass — amen-inspired chop + sub on the 1.", raw"""
        cps!(0.46)
        @d1 p"bd ~ ~ ~ ~ ~ sn ~ ~ ~ bd ~ ~ ~ sn ~"
        @d2 p"hh*16" |> gain(0.4)
        @d3 :subdrop |> n(p"0 ~ ~ ~ 0 ~ 5 ~") |> gain(0.7)
        """),

    _Snippet("techno", :patterns, "genre",
        "Minimal techno — 4-on-the-floor kick, clap on the 2 and 4, percs.", raw"""
        cps!(0.5)
        @d1 p"bd bd bd bd"
        @d2 p"~ cp ~ cp"
        @d3 p"~ hh ~ hh ~ hh ~ hh" |> gain(0.35)
        @d4 p"~ ~ ~ ~ ~ ~ ~ oh"  |> gain(0.4)
        """),

    _Snippet("house", :patterns, "genre",
        "Deep house — 4-on-the-floor, off-beat hats, syncopated snare.", raw"""
        cps!(0.5)
        @d1 p"bd bd bd bd"
        @d2 p"~ cp ~ cp"
        @d3 p"~ hh ~ hh ~ hh ~ hh" |> gain(0.4)
        @d4 p"~ ~ ~ ~ ~ ~ oh ~" |> gain(0.5)
        """),

    _Snippet("breakcore", :patterns, "genre",
        "Breakcore — chopped fast break, ghost notes, kick chaos.", raw"""
        cps!(0.66)
        @d1 p"bd*2 ~ [bd*4] ~ bd ~ [bd*3] ~"
        @d2 p"~ ~ sn ~ ~ sn ~ [sn*2]"
        @d3 p"hh*32" |> gain(0.3)
        """),

    _Snippet("drill", :patterns, "genre",
        "UK drill — sliding 808, triplet hat bursts, sparse snare.", raw"""
        cps!(0.48)
        @d1 p"bd ~ ~ bd ~ ~ bd ~"
        @d2 p"~ ~ cp ~ ~ ~ cp ~"
        @d3 p"hh hh [hh*3] hh [hh*3] hh hh hh" |> gain(0.4)
        @d4 :subdrop |> n(p"0 ~ -2 ~ -5 ~ ~ ~") |> gain(0.7)
        """),

    _Snippet("dembow", :patterns, "genre",
        "Reggaeton dembow — classic boom-ch-boom-chick pattern.", raw"""
        cps!(0.5)
        @d1 p"bd ~ ~ cp bd cp ~ cp"
        @d2 p"hh*8" |> gain(0.4)
        """),

    _Snippet("boombap", :patterns, "genre",
        "Boom-bap hip-hop — heavy kick on 1+3, snare on 2+4, swung hats.", raw"""
        cps!(0.42)
        @d1 p"bd ~ ~ ~ bd ~ bd ~"
        @d2 p"~ ~ sn ~ ~ ~ sn ~"
        @d3 p"hh ~ hh ~ hh ~ hh ~" |> gain(0.4)
        """),

    _Snippet("lofi_hiphop", :patterns, "genre",
        "Lofi hip-hop — slower boom-bap with mellow ghost notes.", raw"""
        cps!(0.38)
        @d1 :lofikick |> n(p"0 ~ ~ ~ 0 ~ 0 ~") |> gain(0.7)
        @d2 p"~ ~ sn ~ ~ ~ sn ~"
        @d3 :lofihat |> n(p"0*16") |> gain(0.3)
        @d4 :chordstab |> n(p"<0 5 -2 3>") |> gain(0.45)
        """),

    _Snippet("phonk", :patterns, "genre",
        "Phonk — cowbell, triplet hi-hats, deep 808 slides.", raw"""
        cps!(0.46)
        @d1 p"bd ~ ~ bd ~ bd ~ ~"
        @d2 p"~ cp ~ ~ ~ cp ~ ~"
        @d3 p"[hh hh hh]*4" |> gain(0.35)
        @d4 p"cb ~ ~ cb ~ ~ cb ~" |> gain(0.5)
        @d5 :subdrop |> n(p"0 ~ ~ 0 -3 ~ ~ ~") |> gain(0.7)
        """),

    _Snippet("witch_house", :patterns, "genre",
        "Witch house — slow, sparse, eerie pads + slowed kicks.", raw"""
        cps!(0.28)
        @d1 p"bd ~ ~ ~ ~ ~ ~ ~ ~ ~ bd ~ ~ ~ ~ ~"
        @d2 p"~ ~ ~ ~ cp ~ ~ ~ ~ ~ ~ ~ cp ~ ~ ~"
        @d3 :ghostpad |> n(p"<0 -3 -5 -7>") |> gain(0.4)
        """),

    _Snippet("bossanova", :patterns, "genre",
        "Bossa nova clave — partido alto-ish pattern.", raw"""
        cps!(0.5)
        @d1 p"bd ~ ~ bd ~ ~ bd ~"
        @d2 p"~ ~ cp ~ cp ~ ~ cp"
        @d3 p"hh hh ~ hh hh hh ~ hh" |> gain(0.35)
        """),

    # ── Pattern helpers ─────────────────────────────────────────────
    _Snippet("euclidean_layers", :patterns, "rhythm",
        "Three Euclidean rhythms layered — endless polyrhythmic groove.", raw"""
        @d1 p"bd(3,8)"
        @d2 p"sn(5,16)" |> gain(0.6)
        @d3 p"hh(7,16)" |> gain(0.4)
        """),

    _Snippet("polyrhythm_3_4", :patterns, "rhythm",
        "3-against-4 polyrhythm — classic tension groove.", raw"""
        @d1 p"bd*3"
        @d2 p"hh*4" |> gain(0.4)
        """),

    _Snippet("polyrhythm_5_4", :patterns, "rhythm",
        "5-against-4 — angular and unsettling.", raw"""
        @d1 p"bd*5"
        @d2 p"sn*4" |> gain(0.5)
        """),

    _Snippet("call_response", :patterns, "rhythm",
        "Call-and-response — alternate between two motifs each cycle.", raw"""
        @d1 p"<[bd hh sn hh] [bd*2 ~ sn ~]>"
        """),

    _Snippet("ghost_notes", :patterns, "rhythm",
        "Heavy kicks with ghost notes between — accent variation.", raw"""
        @d1 p"bd*2 [~ bd] sn [~ bd] bd*2 sn ~"
        @d2 p"hh*16" |> gain(0.25)
        """),

    # ── Synth pane: SynthDef skeletons ──────────────────────────────
    _Snippet("synth_skeleton", :synth, "skeleton",
        "Minimal SynthDef boilerplate ready to fill in.", raw"""
        SynthDef(\myname, { |out, pan = 0, freq = 220, sustain = 0.5, gain = 0.5|
            var osc, amp, sig;
            osc = SinOsc.ar(freq);
            amp = EnvGen.kr(Env.linen(0.01, sustain, 0.1), doneAction: 2);
            sig = osc * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),
    _Snippet("synth_filtered", :synth, "skeleton",
        "Saw → resonant filter → envelope, the bread-and-butter synth.", raw"""
        SynthDef(\myname, { |out, pan = 0, freq = 220, sustain = 0.5, gain = 0.5,
                            cutoff = 2000, resonance = 0.4|
            var osc, filt, amp, sig;
            osc = Saw.ar(freq);
            filt = RLPF.ar(osc, cutoff, resonance);
            amp = EnvGen.kr(Env.linen(0.005, sustain, 0.05), doneAction: 2);
            sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),

    # ── Synth pane: envelopes ───────────────────────────────────────
    _Snippet("env_adsr", :synth, "envelope",
        "ADSR envelope. Needs a gate arg in the SynthDef params.", raw"""
        amp = EnvGen.kr(Env.adsr(attack, decay, sustain_level, release),
                        gate, doneAction: 2);
        """),
    _Snippet("env_perc", :synth, "envelope",
        "One-shot percussive envelope. No gate needed.", raw"""
        amp = EnvGen.kr(Env.perc(attack, sustain, 1, -4), doneAction: 2);
        """),
    _Snippet("env_linen", :synth, "envelope",
        "Linear-attack/sustain/release — predictable note length.", raw"""
        amp = EnvGen.kr(Env.linen(attack, sustain, release), doneAction: 2);
        """),
    _Snippet("env_pluck", :synth, "envelope",
        "Sharp pluck envelope with exponential decay.", raw"""
        amp = EnvGen.kr(Env([0, 1, 0], [0.001, sustain], [0, -8]),
                        doneAction: 2);
        """),

    # ── Synth pane: filters ─────────────────────────────────────────
    _Snippet("rlpf_env", :synth, "filter",
        "Resonant LPF with envelope on cutoff — acid filter sweep.", raw"""
        var cenv = EnvGen.kr(Env.perc(0.001, 0.3, 1, -3)) * 4;
        filt = RLPF.ar(osc, cutoff * (1 + cenv), q);
        """),
    _Snippet("lfo_filter", :synth, "filter",
        "LFO-modulated cutoff — wobble bass core.", raw"""
        var lfo = SinOsc.kr(rate).range(low, high);
        filt = RLPF.ar(osc, lfo, q);
        """),
    _Snippet("formant", :synth, "filter",
        "Bandpass at a swept formant freq — vowel-y mouth sounds.", raw"""
        var vow = SinOsc.kr(vowel_rate).range(400, 1800);
        filt = BPF.ar(osc, vow, 0.25);
        """),

    # ── Synth pane: oscillator stacks ───────────────────────────────
    _Snippet("saw_stack", :synth, "osc",
        "Detuned saw stack (super-saw) for fat leads / pads.", raw"""
        var saws = Mix.ar(Array.fill(5, { |i|
            Saw.ar(freq * (1 + ((i - 2) * 0.012)))
        })) * 0.2;
        """),
    _Snippet("fm_2op", :synth, "osc",
        "Classic 2-op FM. mratio drives timbre, mindex its evolution.", raw"""
        var mod = SinOsc.ar(freq * mratio) *
                  EnvGen.kr(Env([mindex, 0.3], [decay], \exp)) * freq;
        sig = SinOsc.ar(freq + mod);
        """),
    _Snippet("karplus", :synth, "osc",
        "Karplus-Strong pluck — noise burst into a feedback delay.", raw"""
        var exc = WhiteNoise.ar * EnvGen.kr(Env.perc(0, 0.005));
        var loop = CombL.ar(exc, 0.05, 1 / freq, sustain);
        loop = LPF.ar(loop, freq * 4);
        """),
    _Snippet("sub_drop", :synth, "osc",
        "Pitch-drop sine for kick / sub.", raw"""
        var pitch = EnvGen.kr(Env([start_freq, freq], [drop], \exp));
        sig = SinOsc.ar(pitch);
        """),

    # ── Synth pane: output stages ───────────────────────────────────
    _Snippet("dirt_out", :synth, "output",
        "Standard SuperDirt output line.", raw"""
        OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        """),
    _Snippet("tanh_drive", :synth, "output",
        "Soft saturation — warm clip without harsh distortion.", raw"""
        sig = (sig * (1 + drive)).tanh;
        """),
    _Snippet("stereo_widen", :synth, "output",
        "Cheap stereo widening via tiny L/R delays.", raw"""
        var ch_l = DelayN.ar(sig, 0.05, 0.011);
        var ch_r = DelayN.ar(sig, 0.05, 0.017);
        sig = (ch_l + ch_r) * 0.5;
        """),
]

"""
    _snippets_for_context(ctx) -> Vector{_Snippet}

Filter the global snippet table to entries whose context is `ctx` or
`:any`. `ctx` should be either `:patterns` or `:synth`.
"""
function _snippets_for_context(ctx::Symbol)
    [s for s in _SNIPPETS if s.context === ctx || s.context === :any]
end
