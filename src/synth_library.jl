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
    source::String        # the .scd body (compiled SC, plus DSL recipe comment)
end

"""
    _dsl_entry(name, category, description, dsl_text; params)

Parse and evaluate `dsl_text` (a Julia expression that produces a
SynthDSL.Sig) inside the SynthDSL module, compile to a SynthDef
via `SynthDSL.build_synth`, and bundle the DSL source as a header
comment so the user sees both forms when they open the entry.
"""
function _dsl_entry(name::String, category::String, description::String,
                    dsl_text::String;
                    params::NamedTuple = NamedTuple(),
                    auto_env::Bool = true,
                    auto_gain::Bool = true)
    sig = Core.eval(SynthDSL, Meta.parse(dsl_text))
    sc  = SynthDSL.build_synth(Symbol(name), sig;
                               params = params,
                               auto_env = auto_env,
                               auto_gain = auto_gain)
    indented = "//   " * replace(strip(dsl_text), "\n" => "\n//   ")
    body = """
        // ─ DSL recipe (Julia / Ressac.SynthDSL) ────────────────
        $indented
        // ────────────────────────────────────────────────────────

        $sc"""
    _SynthLibEntry(name, category, description, body)
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
]
