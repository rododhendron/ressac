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

    # ── Patterns: cheatsheets — commented reference blocks ──────────
    # Insert one of these to see what's available. Lines are Julia
    # comments so they sit in the buffer without breaking eval.
    _Snippet("cheat_combinators", :patterns, "reference",
        "Cheatsheet: every pattern combinator with a one-line example.", raw"""
        # ── Combinators (pattern transforms) ──
        # pure(:bd)                  — pattern firing :bd once per cycle
        # silence(Symbol)            — empty pattern (placeholder)
        # fast(2, p)  /  p |> fast(2)        — ×2 speed
        # slow(2, p)  /  p |> slow(2)        — ÷2 speed (dilate)
        # density(2, p)              — alias for fast
        # rev(p)                     — reverse events within each cycle
        # every(4, fast(2), p)       — apply fast(2) every 4th cycle
        # every(4, rev, p)           — reverse every 4th cycle
        # stack(p, q, r)             — play patterns in parallel
        # cat([p, q, r])             — alternate one per cycle
        # mask(p, q::Pattern{Bool})  — gate p by q (true = let through)
        # gate(:bd, p"1 0 1 1")      — substitute :bd for every "1" event
        # degree(x)                  — note as scale degree (set :scale first)
        # n(x)                       — sample variant index OR semitone offset
        """),

    _Snippet("cheat_controls", :patterns, "reference",
        "Cheatsheet: every effect / control op and its composition rule.", raw"""
        # ── Controls (chain with |>) ──
        # gain(0.8)        — volume multiplier        (composes ×)
        # pan(0.3)         — stereo position          (last write wins)
        # speed(0.5)       — sample playback rate     (composes ×)
        # lpf(2000)        — low-pass cutoff Hz       (composes min — strictest wins)
        # hpf(200)         — high-pass cutoff Hz      (composes max)
        # n(p"0 3 5")      — sample variant / semitones (overwrite)
        # room(0.4)        — reverb send 0..1
        # delay(0.4)       — delay send 0..1
        # delaytime(0.25)  — delay time in beats (¼ = 16th note at 4 cps)
        # delayfeedback(0.5)
        # shape(0.2)       — waveshaper drive
        # attack / release / sustain / hold — envelope shape per note
        # cutoff / resonance — synth-internal filter
        # vowel(:a/:e/:i/:o/:u)  — formant filter
        # crush(8) / coarse(4)   — bit-crush / sample-rate reduce
        # accelerate(2) — pitch sweep semis/sec
        # set(:any_key, val)     — override any OSC param verbatim
        """),

    _Snippet("cheat_mini", :patterns, "reference",
        "Cheatsheet: the mini-notation grammar inside p\"…\".", raw"""
        # ── Mini-notation (inside p"…") ──
        # bd hh sn hh        — 4 equal events per cycle
        # ~                  — rest / silence
        # bd*4               — repeat 4 times inside the slot (subdivide)
        # bd!3               — same bd in 3 successive slots (no subdivide)
        # [bd bd]            — group: 2 events in one slot's time
        # <bd sn cp>         — alternate: one per cycle, round-robin
        # bd(3,8)            — Euclidean rhythm: 3 hits over 8 steps
        # bd:2               — variant index — bd, bd:1, bd:2, ...
        # bd@2               — weight: this token gets 2 slots
        # combine: <[bd*2] sn> ~ bd ~
        """),

    _Snippet("cheat_commands", :patterns, "reference",
        "Cheatsheet: every :ex-command grouped by purpose.", raw"""
        # ── Tempo & transport ──
        # :cps 0.5            set tempo (cycles/sec). 0.5 = 120 BPM @ 4 beats/cycle
        # :bpm  /  :tap-tempo tap-set tempo: 2+ Space hits then Enter
        # :hush  /  :panic    soft / nuclear stop
        # :pause              freeze render to mouse-select & copy

        # ── Slots ──
        # :mute d1            mute @d1 (toggle with `m` in normal mode)
        # :unmute d1
        # :solo d1            mute everything else
        # E (normal mode)     eval every @dN block in the buffer

        # ── Browse / library ──
        # :browse             samples + synths + instruments picker
        # :lib                synth library (built-in + your saved ones)
        # :sccode             search sccode.org
        # :sccode <id>        import one entry
        # :doc <name>         description + usage examples
        # :wiki  /  :guide    in-app docs

        # ── Snippets / starters ──
        # :snip               this picker
        # :starter house      genre starter pack (house/dnb/techno/…)

        # ── Sessions ──
        # :save  <name>       save patterns buffer
        # :load  <name>       reload it (then press E to eval)
        # :sessions           list saved files

        # ── Tap / piano ──
        # :tap                tap a rhythm; Enter auto-detects period + cps
        # :tap-strict         no loop detection (single-bar quantize)
        # :piano <synth>      keyboard plays chromatic semitones
        # :piano-rec          same + records into a @dN line

        # ── Scope / visual ──
        # :scope amp|wave|spectrum|xy|goni|spectrogram|peak|pitch|onset|hist|corr
        # :theme <name>       switch theme  (:theme alone lists)
        # :safety on|off      limiter + DC block + 10 Hz HPF
        """),

    _Snippet("cheat_pipes", :patterns, "reference",
        "Cheatsheet: how |> threads through pattern → control → output.", raw"""
        # ── Pipe-chain anatomy ──
        # Pattern  |>  control  |>  control  …
        #   :bd                    a bare symbol = pure(:bd) (lifted)
        #   p"bd ~ sn ~"           mini-notation literal
        #   gate(:bd, p"1 0 1 1")  named pattern
        #
        # Then each |> wraps the pattern in a ControlMap layer:
        #
        #   @d1 p"bd hh sn hh" |> gain(0.8) |> lpf(1500) |> pan(0.3)
        #
        # @dN macro is the final stage — installs the pattern at the slot.
        # Composition rules (most useful):
        #   gain * gain → ×          lpf min lpf → strictest
        #   pan / n / room / delay → overwrite (last wins)
        """),

    _Snippet("helpers_tour", :patterns, "reference",
        "Working example showcasing helpers — eval & iterate.", raw"""
        cps!(0.5)
        @d1 p"bd*4" |> gain(0.9)
        @d2 p"~ sn ~ sn" |> gain(0.7) |> room(0.2)
        @d3 p"hh*8" |> gain(0.35) |> hpf(4000) |> pan(p"0.4 -0.4")
        @d4 :bass |> n(p"0 0 3 5") |> gain(0.6) |> lpf(800)
        # Try:
        #   m on @d2     → mute the snare
        #   :solo d3     → only the hat
        #   :tap         → tap a rhythm to replace @d5
        #   :save demo   → snapshot this state
        """),

    # ── Synth pane: SynthDef skeletons ──────────────────────────────
    _Snippet("synth_skeleton", :synth_sc, "skeleton",
        "Minimal SynthDef boilerplate ready to fill in.", raw"""
        SynthDef(\myname, { |out, pan = 0, freq = 220, sustain = 0.5, gain = 0.5|
            var osc, amp, sig;
            osc = SinOsc.ar(freq);
            amp = EnvGen.kr(Env.linen(0.01, sustain, 0.1), doneAction: 2);
            sig = osc * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """),
    _Snippet("synth_filtered", :synth_sc, "skeleton",
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
    _Snippet("env_adsr", :synth_sc, "envelope",
        "ADSR envelope. Needs a gate arg in the SynthDef params.", raw"""
        amp = EnvGen.kr(Env.adsr(attack, decay, sustain_level, release),
                        gate, doneAction: 2);
        """),
    _Snippet("env_perc", :synth_sc, "envelope",
        "One-shot percussive envelope. No gate needed.", raw"""
        amp = EnvGen.kr(Env.perc(attack, sustain, 1, -4), doneAction: 2);
        """),
    _Snippet("env_linen", :synth_sc, "envelope",
        "Linear-attack/sustain/release — predictable note length.", raw"""
        amp = EnvGen.kr(Env.linen(attack, sustain, release), doneAction: 2);
        """),
    _Snippet("env_pluck", :synth_sc, "envelope",
        "Sharp pluck envelope with exponential decay.", raw"""
        amp = EnvGen.kr(Env([0, 1, 0], [0.001, sustain], [0, -8]),
                        doneAction: 2);
        """),

    # ── Synth pane: filters ─────────────────────────────────────────
    _Snippet("rlpf_env", :synth_sc, "filter",
        "Resonant LPF with envelope on cutoff — acid filter sweep.", raw"""
        var cenv = EnvGen.kr(Env.perc(0.001, 0.3, 1, -3)) * 4;
        filt = RLPF.ar(osc, cutoff * (1 + cenv), q);
        """),
    _Snippet("lfo_filter", :synth_sc, "filter",
        "LFO-modulated cutoff — wobble bass core.", raw"""
        var lfo = SinOsc.kr(rate).range(low, high);
        filt = RLPF.ar(osc, lfo, q);
        """),
    _Snippet("formant", :synth_sc, "filter",
        "Bandpass at a swept formant freq — vowel-y mouth sounds.", raw"""
        var vow = SinOsc.kr(vowel_rate).range(400, 1800);
        filt = BPF.ar(osc, vow, 0.25);
        """),

    # ── Synth pane: oscillator stacks ───────────────────────────────
    _Snippet("saw_stack", :synth_sc, "osc",
        "Detuned saw stack (super-saw) for fat leads / pads.", raw"""
        var saws = Mix.ar(Array.fill(5, { |i|
            Saw.ar(freq * (1 + ((i - 2) * 0.012)))
        })) * 0.2;
        """),
    _Snippet("fm_2op", :synth_sc, "osc",
        "Classic 2-op FM. mratio drives timbre, mindex its evolution.", raw"""
        var mod = SinOsc.ar(freq * mratio) *
                  EnvGen.kr(Env([mindex, 0.3], [decay], \exp)) * freq;
        sig = SinOsc.ar(freq + mod);
        """),
    _Snippet("karplus", :synth_sc, "osc",
        "Karplus-Strong pluck — noise burst into a feedback delay.", raw"""
        var exc = WhiteNoise.ar * EnvGen.kr(Env.perc(0, 0.005));
        var loop = CombL.ar(exc, 0.05, 1 / freq, sustain);
        loop = LPF.ar(loop, freq * 4);
        """),
    _Snippet("sub_drop", :synth_sc, "osc",
        "Pitch-drop sine for kick / sub.", raw"""
        var pitch = EnvGen.kr(Env([start_freq, freq], [drop], \exp));
        sig = SinOsc.ar(pitch);
        """),

    # ── Synth pane: output stages ───────────────────────────────────
    _Snippet("dirt_out", :synth_sc, "output",
        "Standard SuperDirt output line.", raw"""
        OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        """),
    _Snippet("tanh_drive", :synth_sc, "output",
        "Soft saturation — warm clip without harsh distortion.", raw"""
        sig = (sig * (1 + drive)).tanh;
        """),
    _Snippet("stereo_widen", :synth_sc, "output",
        "Cheap stereo widening via tiny L/R delays.", raw"""
        var ch_l = DelayN.ar(sig, 0.05, 0.011);
        var ch_r = DelayN.ar(sig, 0.05, 0.017);
        sig = (ch_l + ch_r) * 0.5;
        """),

    # ── Synth pane (DSL / .jl): @synth-macro skeletons ──────────────
    # These insert Julia DSL syntax. Auto-env + auto-gain mean the
    # minimal forms still produce a complete, freeing synth.
    _Snippet("dsl_skeleton", :synth_dsl, "skeleton",
        "Minimal @synth — sine wave, default freq/sustain/gain.", raw"""
        @synth :myname sin_osc(:freq)
        """),
    _Snippet("dsl_filtered", :synth_dsl, "skeleton",
        "Saw → resonant LPF. Add params for cutoff/q.", raw"""
        @synth :myname (freq=220, cutoff=1200, q=0.3) saw(:freq) |> rlpf(:cutoff, :q)
        """),
    _Snippet("dsl_drone", :synth_dsl, "skeleton",
        "No-env drone — runs until you :hush. Note auto_env=false.", raw"""
        @synth :drone (freq=110, sustain=999) (auto_env=false,) saw(:freq) |> rlpf(800, 0.3)
        """),

    _Snippet("dsl_env_perc", :synth_dsl, "envelope",
        "Percussive envelope — fast attack, exponential release.", raw"""
        sin_osc(:freq) |> env_perc(0.001, :sustain)
        """),
    _Snippet("dsl_env_linen", :synth_dsl, "envelope",
        "Linear envelope (attack, sustain, release).", raw"""
        saw(:freq) |> env_linen(0.005, :sustain, 0.05)
        """),
    _Snippet("dsl_env_adsr", :synth_dsl, "envelope",
        "ADSR envelope — needs gate (held note).", raw"""
        sin_osc(:freq) |> env_adsr(0.01, 0.1, 0.7, 0.3; gate=:gate)
        """),
    _Snippet("dsl_env_pluck", :synth_dsl, "envelope",
        "Sharp pluck — short release with curved decay.", raw"""
        saw(:freq) |> env_perc(0.001, 0.2; curve=-8)
        """),

    _Snippet("dsl_lfo_filter", :synth_dsl, "filter",
        "LFO-modulated cutoff — wobble bass core.", raw"""
        @synth :wobble (freq=80, rate=4) saw(:freq) |>
            rlpf(lfo(:rate; low=300, high=2400), 0.4)
        """),
    _Snippet("dsl_filter_env", :synth_dsl, "filter",
        "Filter envelope sweep — acid 303 character.", raw"""
        @synth :acid (freq=80, cutoff=2000, envmod=4) saw(:freq) |>
            rlpf(:cutoff * (1 + :envmod), 0.3)
        """),
    _Snippet("dsl_bandpass", :synth_dsl, "filter",
        "Vowel-y bandpass on noise.", raw"""
        white() |> band_pass(800, 0.25) |> env_perc(0.001, :sustain)
        """),

    _Snippet("dsl_fm", :synth_dsl, "osc",
        "2-op FM. Modulator at freq*mratio, depth via mindex.", raw"""
        @synth :fm (freq=220, mratio=2, mindex=300) sin_osc(:freq + sin_osc(:freq * :mratio) * :mindex)
        """),
    _Snippet("dsl_saw_stack", :synth_dsl, "osc",
        "Detuned saw stack — fat super-saw lead.", raw"""
        @synth :supersaw (freq=220, detune=0.012) (
            saw(:freq) + saw(:freq * (1 + :detune)) + saw(:freq * (1 - :detune))
        ) * 0.33
        """),
    _Snippet("dsl_pluck", :synth_dsl, "osc",
        "Karplus-style pluck via comb-filtered noise.", raw"""
        @synth :pluck (freq=220) white() |> env_perc(0, 0.005) |>
            delay_c(1 / :freq) |> low_pass(:freq * 4)
        """),
    _Snippet("dsl_kick_drop", :synth_dsl, "osc",
        "Sub kick with pitch drop — sine + click.", raw"""
        @synth :kick (sustain=0.4) sin_osc(line(120, 40, 0.05)) |>
            env_perc(0.001, :sustain) |>
            offset((white() |> env_perc(0, 0.005)) * 0.5)
        """),

    _Snippet("dsl_drive", :synth_dsl, "output",
        "Soft tanh saturation — warmth without crunch.", raw"""
        saw(:freq) |> tanh_drive(2.0)
        """),
    _Snippet("dsl_layer", :synth_dsl, "output",
        "Layer multiple oscs with `+`. Useful for thickening.", raw"""
        (sin_osc(:freq) + saw(:freq * 1.005) + pulse(:freq * 0.5, 0.4))
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
