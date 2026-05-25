# Curated synth starters — authored in the Synth DSL, compiled to
# raw SC on entry construction. Each on-disk file gets the DSL
# recipe as a header comment so the user reads the Julia source
# AND the generated SC side-by-side.
#
# A single `raw_sine` entry stays in raw SuperCollider as a
# reference for users who want to compare what the DSL produces
# against hand-written SC.

using .SynthDSL

struct _SynthLibEntry
    name::String          # the SynthDef name (and filename stem)
    category::String
    description::String
    source::String        # body to write — DSL Julia for :dsl mode, raw SC for :sc mode
    mode::Symbol          # :dsl or :sc — picks the file extension on save
end
_SynthLibEntry(name, category, description, source) =
    _SynthLibEntry(name, category, description, source, :sc)

"""
    _dsl_entry(name, category, description, dsl_text; params, auto_env, auto_gain)

Produce a library entry whose body IS the DSL Julia source — opens
directly as a `.jl` synth tab, T evals it, the @synth macro inside
compiles and ships to SC. `dsl_text` is the body of the @synth call
(e.g. `"sin_osc(:freq) |> rlpf(800, 0.3)"`).
"""
function _dsl_entry(name::String, category::String, description::String,
                    dsl_text::String;
                    params::NamedTuple = NamedTuple(),
                    auto_env::Bool = true,
                    auto_gain::Bool = true)
    # Validate the DSL recipe compiles at load time — catches typos
    # in the library itself before the user clicks anything.
    sig = Core.eval(SynthDSL, Meta.parse(dsl_text))
    SynthDSL.build_synth(Symbol(name), sig;
                         params = params,
                         auto_env = auto_env,
                         auto_gain = auto_gain)
    params_str = isempty(params) ? "" : " " * _format_params(params)
    opts_str   = (auto_env && auto_gain) ? "" :
        " (auto_env=$(auto_env), auto_gain=$(auto_gain),)"
    indented = "  " * replace(strip(dsl_text), "\n" => "\n  ")
    body = """
        # $(description)
        # T = test  ·  :w <name> = save as  ·  :dsl = cookbook

        @synth :$(name)$(params_str)$(opts_str) begin
        $(indented)
        end
        """
    _SynthLibEntry(name, category, description, body, :dsl)
end

# Render a NamedTuple as the literal `(key=val, key=val,)` Julia
# notation the @synth macro expects.
function _format_params(params::NamedTuple)
    isempty(params) && return ""
    parts = ["$k=$v" for (k, v) in pairs(params)]
    return "(" * join(parts, ", ") * (length(parts) == 1 ? "," : "") * ")"
end

const _SYNTH_LIBRARY = _SynthLibEntry[
    # ═══════════════════════════════════════════════════════════════
    # Raw SC reference — left in for users who want to see what an
    # untransformed SuperCollider SynthDef looks like.
    # ═══════════════════════════════════════════════════════════════
    _SynthLibEntry(
        "raw_sine", "reference",
        "Raw SuperCollider — a plain sine + Env.linen, no DSL.",
        raw"""
        // raw_sine.scd  —  reference SynthDef in hand-written SC
        //
        // Compare to the DSL versions in the rest of the library:
        // the DSL collapses this into a single line.
        SynthDef(\raw_sine, { |out, pan = 0, freq = 220, sustain = 0.5, gain = 0.5|
            var sig, amp;
            sig = SinOsc.ar(freq);
            amp = EnvGen.kr(Env.linen(0.01, sustain, 0.1), doneAction: 2);
            sig = sig * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """,
    ),

    # ═══════════════════════════════════════════════════════════════
    # Percussion
    # ═══════════════════════════════════════════════════════════════
    _dsl_entry("kick", "perc",
        "Sub kick — sine with fast pitch drop + transient click.",
        """sin_osc(line(120, 40, 0.05)) |> env_perc(0.001, :sustain) |>
           offset((white() |> env_perc(0, 0.005)) * 0.5)""";
        params = (sustain = 0.4,)),

    _dsl_entry("hihat", "perc",
        "Hi-hat — pink noise → high-pass + tight envelope.",
        """pink() |> high_pass(6000) |> band_pass(8000, 0.4) |>
           env_perc(0.001, :sustain)""";
        params = (sustain = 0.08,)),

    _dsl_entry("snare", "perc",
        "Snare — FM body + noise tail.",
        """(sin_osc(:freq + sin_osc(:freq * 1.5) * :freq * 4) |>
            env_perc(0, 0.06)) +
           (white() |> band_pass(4500, 0.3) |> env_perc(0.001, :sustain))""";
        params = (freq = 180, sustain = 0.2)),

    _dsl_entry("clap", "perc",
        "Clap — bursts of bandpassed noise.",
        """white() |> band_pass(1500, 0.5) |> env_perc(0.001, :sustain)""";
        params = (sustain = 0.15,)),

    _dsl_entry("kickbrut", "darksynth",
        "Heavy retro kick — Carpenter-Brut vibes, drive + click.",
        """sin_osc(line(220, :freq, 0.06)) |> tanh_drive(1.4) |>
           env_perc(0.001, :sustain) |>
           offset(pink() |> high_pass(2000) |> env_perc(0, 0.004) |> amp(0.6))""";
        params = (freq = 50, sustain = 0.5)),

    _dsl_entry("glitchhat", "perc",
        "Stuttering noise hat — gated by Dust trigger.",
        """white() |> high_pass(6000) |> env_perc(0.001, :sustain) |>
           amp(trig_kr(dust(80), 0.01))""";
        params = (sustain = 0.15,)),

    # ═══════════════════════════════════════════════════════════════
    # Bass
    # ═══════════════════════════════════════════════════════════════
    _dsl_entry("subdrop", "bass",
        "Pure sub-bass with pitch drop.",
        """sin_osc(line(90, :freq, 0.4)) |> env_linen(0.005, :sustain, 0.1)""";
        params = (freq = 40, sustain = 0.9)),

    _dsl_entry("acid303", "bass",
        "TB-303 acid — saw + RLPF with envelope on cutoff.",
        """saw(:freq) + (sin_osc(:freq * 0.5) * 0.3) |>
           rlpf(:cutoff * (1 + line(4, 0, :decay)), :resonance) |>
           tanh_drive(1.2) |> env_linen(0.005, :sustain, 0.05)""";
        params = (freq = 80, sustain = 0.3, cutoff = 1500, resonance = 0.3, decay = 0.2)),

    _dsl_entry("rezzbass", "bass",
        "Wide wobble bass — sin + saw layer, deep LFO sweep on filter.",
        """(saw(:freq) + saw(:freq * 0.5) * 0.6) |>
           rlpf(lfo(:rate; low=500, high=2500), 0.25) |>
           tanh_drive(1.5)""";
        params = (freq = 50, sustain = 1.0, rate = 4)),

    _dsl_entry("growlbass", "bass",
        "Formant-shifted growling bass.",
        """saw(:freq) |> band_pass(lfo(3; low=400, high=1800), 0.18) |>
           offset(saw(:freq) |> low_pass(600) |> amp(0.4)) |>
           tanh_drive(1.4)""";
        params = (freq = 65, sustain = 0.6)),

    _dsl_entry("chompy", "bass",
        "Sync-bass — hard-syncing saws + filter.",
        """saw(:freq) |> rlpf(:cutoff, :q) |>
           tanh_drive(1.5)""";
        params = (freq = 70, sustain = 0.3, cutoff = 1800, q = 0.3)),

    _dsl_entry("lofibass", "lofi",
        "Round sine bass with subtle harmonic warmth.",
        """sin_osc(:freq) + (sin_osc(:freq * 2) |> amp(0.1)) |> tanh_drive(1.05)""";
        params = (freq = 80, sustain = 0.4)),

    _dsl_entry("dustbass", "witch",
        "Lo-fi bass — bit-crushed and dark.",
        """saw(:freq) |> decimator(11025, 4) |> low_pass(1200)""";
        params = (freq = 70, sustain = 0.4)),

    # ═══════════════════════════════════════════════════════════════
    # Lead / arp
    # ═══════════════════════════════════════════════════════════════
    _dsl_entry("darklead", "darksynth",
        "Gritty detuned saw lead.",
        """(saw(:freq) + saw(:freq + :detune) + saw(:freq - :detune * 0.7)) |>
           amp(0.3) |> rlpf(:cutoff, 0.4) |> tanh_drive(1.2)""";
        params = (freq = 220, sustain = 0.4, detune = 7, cutoff = 3000)),

    _dsl_entry("arpdriver", "darksynth",
        "Fast 16th arpeggio voice — plucky filter envelope.",
        """pulse(:freq, 0.45) |>
           rlpf(:cutoff * (1 + line(2, 0, :sustain)), 0.3) |>
           env_perc(0.001, :sustain)""";
        params = (freq = 220, sustain = 0.12, cutoff = 2200)),

    _dsl_entry("fmbell", "lead",
        "Classic 2-op FM bell with index envelope.",
        """sin_osc(:freq + sin_osc(:freq * :mratio) *
                   line(:mindex, :mindex * 0.3, :decay) * :freq)""";
        params = (freq = 440, sustain = 1.2, mratio = 1.41, mindex = 5, decay = 0.8)),

    _dsl_entry("bellsynth", "lead",
        "Additive bell — sum of sines at inharmonic partials.",
        """sin_osc(:freq) |> env_perc(0, :sustain, curve=-5) |>
           offset(sin_osc(:freq * 2.76) |> env_perc(0, :sustain * 0.7) |> amp(0.5)) |>
           offset(sin_osc(:freq * 5.4) |> env_perc(0, :sustain * 0.5) |> amp(0.3)) |>
           amp(0.4)""";
        params = (freq = 440, sustain = 2.5)),

    _dsl_entry("plucky", "lead",
        "Karplus-Strong pluck — comb filter feedback loop.",
        """white() |> env_perc(0, 0.005) |> comb_l(1 / :freq, :sustain, 0.05) |>
           low_pass(:freq * 4)""";
        params = (freq = 220, sustain = 0.8)),

    _dsl_entry("screwlead", "witch",
        "Pitched-down detuned lead — slow vibrato.",
        """(saw(:freq + sin_osc(5) * 4) + saw(:freq * 1.005 + sin_osc(5) * 4)) |>
           amp(0.4) |> low_pass(1500)""";
        params = (freq = 165, sustain = 1.2)),

    # ═══════════════════════════════════════════════════════════════
    # Pads
    # ═══════════════════════════════════════════════════════════════
    _dsl_entry("softpad", "pad",
        "Detuned saw stack + slow filter sweep — ambient pad.",
        """(saw(:freq) + saw(:freq * 1.012) + saw(:freq * 0.988) +
            saw(:freq * 1.005) + saw(:freq * 0.995)) |> amp(0.18) |>
           rlpf(:cutoff * lfo(0.1; low=0.8, high=1.2), :q) |>
           env_linen(:attack, :sustain - :attack - :release, :release; curve=:sin)""";
        params = (freq = 220, sustain = 2.5, attack = 0.5, release = 1.5, cutoff = 2500, q = 0.5),
        auto_env = false),

    _dsl_entry("darkpad", "darksynth",
        "Cinematic dark pad — wide super-saw, slow filter.",
        """(saw(:freq) + saw(:freq * 1.012) + saw(:freq * 0.988) +
            saw(:freq * 1.025) + saw(:freq * 0.975) + saw(:freq * 1.005)) |>
           amp(0.18) |> rlpf(:cutoff * lfo(0.08; low=0.6, high=1.2), :q) |>
           env_linen(:attack, :sustain - :attack - :release, :release; curve=:sin)""";
        params = (freq = 110, sustain = 4.0, attack = 0.8, release = 1.5, cutoff = 800, q = 0.4),
        auto_env = false),

    _dsl_entry("airpad", "angel",
        "Airy sine stack with chorus-style delays.",
        """(sin_osc(:freq) + sin_osc(:freq * 1.003) + sin_osc(:freq * 0.997) +
            sin_osc(:freq * 1.005)) |> amp(0.25)""";
        params = (freq = 440, sustain = 3.0)),

    _dsl_entry("glasspad", "angel",
        "Glassy FM pad — high mratio, evolving index.",
        """sin_osc(:freq + sin_osc(:freq * 4) *
                   lfo(0.3; low=0.2, high=2) * :freq)""";
        params = (freq = 440, sustain = 3.0)),

    _dsl_entry("ghostpad", "witch",
        "Tremolo-driven airy pad — amplitude pulse.",
        """(sin_osc(:freq) + sin_osc(:freq * 2) * 0.3) |>
           band_pass(1800, 0.6) |> amp(lfo(1.5; low=0.2, high=1))""";
        params = (freq = 220, sustain = 3.0)),

    # ═══════════════════════════════════════════════════════════════
    # Keys / lofi
    # ═══════════════════════════════════════════════════════════════
    _dsl_entry("lofikey", "lofi",
        "Detuned-saw piano-ish key — slightly out of tune.",
        """(sin_osc(:freq) + (saw(:freq + 4) |> amp(0.2)) +
            (sin_osc(:freq * 2) |> amp(0.15))) |> low_pass(2200)""";
        params = (freq = 330, sustain = 0.8)),

    _dsl_entry("mellowfm", "lofi",
        "Soft 2-op FM key — low modulation index.",
        """sin_osc(:freq + sin_osc(:freq * 2) * line(1.5, 0.1, :sustain * 0.7) * :freq)""";
        params = (freq = 330, sustain = 0.8)),

    _dsl_entry("chordstab", "lofi",
        "Minor-triad lofi chord stab.",
        """(saw(:freq) + saw(:freq * 1.189) + saw(:freq * 1.498)) |>
           amp(0.25) |> low_pass(2200)""";
        params = (freq = 220, sustain = 0.4)),

    # ═══════════════════════════════════════════════════════════════
    # Effects / one-shots
    # ═══════════════════════════════════════════════════════════════
    _dsl_entry("lazerzap", "fx",
        "Sci-fi zap — pitch-fall sine + noise crackle.",
        """sin_osc(x_line(3000, 200, :sustain)) |>
           offset(white() |> env_perc(0, 0.03) |> amp(0.5))""";
        params = (sustain = 0.2,)),

    _dsl_entry("darkriser", "fx",
        "Tension riser — noise + sweeping filter UP.",
        """(white() + brown() * 0.4) |> rlpf(x_line(200, 8000, :sustain), 0.3)""";
        params = (sustain = 2.0,),
        auto_env = false),

    _dsl_entry("vinylcrackle", "lofi",
        "Vinyl crackle texture — Dust + pink hiss.",
        """((dust(8) |> amp(0.7)) + (pink() |> amp(0.04)))""";
        params = (sustain = 1.0,),
        auto_env = false,
        auto_gain = false),

    # ═══════════════════════════════════════════════════════════════
    # 909 drum kit — the canonical electronic drum set, ported as
    # DSL recipes so the user has nameable, editable building blocks.
    # All 8 entries use the `tr909` category so they cluster in the
    # synth-library picker. SuperDirt already ships 909 SAMPLES under
    # /dirt/*909*; these are synthesised versions you can tweak live.
    # ═══════════════════════════════════════════════════════════════
    _dsl_entry("k909", "tr909",
        "909-style kick — sine pitch drop + click attack + saturation.",
        """(sin_osc(line(180, :freq, 0.04)) |> tanh_drive(1.2) |>
            env_perc(0.001, :sustain)) +
           (white() |> high_pass(1500) |> env_perc(0, 0.003) |> amp(0.4))""";
        params = (freq = 50, sustain = 0.35)),

    _dsl_entry("s909", "tr909",
        "909-style snare — tone body + noise burst + sharp transient.",
        """(sin_osc(:freq) |> env_perc(0, 0.03) |> amp(0.6)) +
           (white() |> band_pass(2500, 0.4) |> env_perc(0.001, :sustain) |> amp(0.9))""";
        params = (freq = 230, sustain = 0.13)),

    _dsl_entry("hh909", "tr909",
        "909 closed hat — square-rich noise through tight HPF.",
        """((white() |> high_pass(7000)) + (pulse(8000, 0.5) |> amp(0.3))) |>
           env_perc(0.001, :sustain)""";
        params = (sustain = 0.04,)),

    _dsl_entry("oh909", "tr909",
        "909 open hat — longer release with metallic sheen.",
        """((white() |> high_pass(6000)) + (pulse(8500, 0.5) |> amp(0.25))) |>
           env_perc(0.002, :sustain; curve = -3)""";
        params = (sustain = 0.35,)),

    _dsl_entry("cp909", "tr909",
        "909 clap — multi-burst bandpassed noise stack.",
        """white() |> band_pass(1500, 0.45) |>
           env_pairs([0, 0.005, 0.01, 0.015, 0.05, :sustain],
                     [0,    1,   0.5,    1,    1,     0])""";
        params = (sustain = 0.18,)),

    _dsl_entry("rim909", "tr909",
        "909 rimshot — bright tonal click with tiny ring.",
        """(pulse(1700, 0.3) + pulse(2300, 0.3)) |> high_pass(1200) |>
           env_perc(0.001, :sustain)""";
        params = (sustain = 0.05,)),

    _dsl_entry("ride909", "tr909",
        "909-flavoured ride — high pulses summed and bandpassed.",
        """((pulse(4000, 0.5) + pulse(5300, 0.5) + pulse(7200, 0.5)) |>
            high_pass(3500)) |>
           env_perc(0.002, :sustain; curve = -2)""";
        params = (sustain = 0.6,)),

    _dsl_entry("tom909", "tr909",
        "909 tom — pitched sine with noise transient.",
        """(sin_osc(line(:freq * 2, :freq, 0.08)) |>
            env_perc(0.001, :sustain)) +
           (white() |> band_pass(800, 0.6) |> env_perc(0, 0.004) |> amp(0.3))""";
        params = (freq = 110, sustain = 0.25)),
]
