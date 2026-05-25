# Static docs + starter sketches surfaced through `:doc` and `:starter`.
# Goal: short, plain-language explanations a junior can read while live
# coding. Keep each entry one or two lines.

"""
    _PARAM_DOCS

Maps OSC param name → short prose description. Surfaced via `:doc <name>`.
The same map is reused by `:browse` to enrich hover info if we add it
later.
"""
const _PARAM_DOCS = Dict{String,String}(
    # Envelope
    "attack"      => "Time to reach full volume after a note triggers (sec). 0.01=instant, 0.5=soft fade in.",
    "release"     => "Time to fade out after the note ends (sec). 0.1=staccato, 0.5=normal, 2=long tail.",
    "sustain"     => "Level held while the note is on (0-1). Affects ADSR shape.",
    "hold"        => "How long the envelope stays at peak before release (sec).",
    "legato"      => "Note overlap (0 = no overlap, 1 = full hold). Use for connected lines.",
    # Filters
    "cutoff"      => "Filter frequency for the synth's internal filter (Hz). Lower = darker.",
    "resonance"   => "Filter resonance (0-1). Higher = more peak around cutoff, 0.5+ starts to whistle.",
    "lpf"         => "Low-pass filter (Hz). Cut everything above. <300 = sub only, 5000 = bright.",
    "hpf"         => "High-pass filter (Hz). Cut everything below. 200 = remove rumble, 1000 = thin.",
    "bandq"       => "Band-pass filter Q (resonance/width).",
    "bandf"       => "Band-pass filter frequency (Hz).",
    "hcutoff"     => "Synth-internal high-pass cutoff.",
    "hresonance"  => "Synth-internal high-pass resonance.",
    # Gain / mix
    "gain"        => "Volume multiplier. 1=neutral, 0.5=half, 2=double. Composes ×.",
    "pan"         => "Stereo position. 0=left, 0.5=center, 1=right (some setups: -1 to 1).",
    "n"           => "Note offset (semitones) for synths, or sample-variant index for sample banks.",
    "freq"        => "Raw frequency in Hz. Sets the synth's freq param directly (bypasses n→freq mapping).",
    "speed"       => "Playback speed. 0.5=octave down + slower, 2=octave up + faster. Composes ×.",
    # --- CORE CONCEPTS ---
    "cps"         => "Cycles per second — Ressac's tempo unit. 0.5 = 1 cycle / 2s (30 BPM @ 4 beats/cycle), 0.8 = ~48 BPM, 0.3 = 18 BPM. cps!(x) sets it live, :cps x is the TUI form.",
    "cps!"        => "cps!(x) — set the live scheduler tempo in cycles/sec. Equivalent to :cps x at the command line.",
    "cycle"       => "Ressac's time unit. Every pattern repeats once per cycle. A `p\"a b c d\"` produces 4 events evenly across one cycle.",
    "@dN"         => "@d1, @d2, ... @d64 — slot macros. `@d1 pattern` installs `pattern` at slot d1; assigning a new value re-evals.",
    "d!"          => "d!(:dN, pattern) — set a slot from Julia code (REPL or :julia hooks). Same effect as @dN.",
    "unset!"      => "unset!(:dN) — stop slot dN. Equivalent to commenting the line with `m`.",
    "hush_all!"   => "hush_all!() — stop every slot. Panic button.",
    "slot"        => "A named pattern channel (:d1 to :d64). The scheduler queries each slot every cycle and ships its events to OSC.",
    # --- COMBINATORS (pattern transforms) ---
    "pure"        => "pure(v) — pattern that fires v once per cycle. The atom you build on.",
    "silence"     => "silence(T) — empty pattern of type T. Useful as a placeholder.",
    "fast"        => "fast(n, p) or `p |> fast(n)` — compress time ×n. fast(2) plays twice in a cycle.",
    "slow"        => "slow(n, p) or `p |> slow(n)` — dilate ×n. slow(2) plays once over 2 cycles.",
    "density"     => "Alias for fast — TidalCycles compat.",
    "rev"         => "rev(p) — reverse events within each cycle.",
    "every"       => "every(N, f, p) — apply transform f every Nth cycle. e.g. every(4, fast(2)).",
    "stack"       => "stack(p, q, ...) — play patterns in parallel (layer them).",
    "cat"         => "cat([p, q, r]) — cycle through patterns, one per cycle.",
    "mask"        => "mask(p, q::Pattern{Bool}) — gate p by q. Where q is true, p plays.",
    "gate"        => "gate(:name, p\"1 0 0 1 …\") — substitute :name for every non-silence event of p. Short alias for rhythm masks.",
    "degree"      => "degree(x) — like n(x) but interprets x as a scale-degree in the current :scale (use `:scale minor` first).",
    # --- MINI-NOTATION (inside p\"…\") ---
    ""           => "p\"bd hh sn\" — mini-notation literal. Each whitespace-separated token = 1 event in the cycle.",
    "~"           => "~ inside p\"…\" — silence (no event for that slot).",
    "*"           => "name*N inside p\"…\" — repeat name N times inside its slot. p\"bd*4\" = 4 hits/cycle.",
    "!"           => "name!N — give name N times the weight (takes N slots).",
    "[]"          => "[a b] inside p\"…\" — sub-group (treated as one slot, recursively divided).",
    "<>"          => "<a b c> — alternation: a on cycle 0, b on cycle 1, c on cycle 2, repeat.",
    "()"          => "name(k,n) — Euclidean rhythm: k hits over n steps. p\"bd(3,8)\" = classic 3-against-8.",
    # FX
    "room"        => "Reverb send. 0=dry, 1=wet. Goes through SuperDirt's room reverb.",
    "delay"       => "Delay send. 0=dry, 1=wet.",
    "delaytime"   => "Delay time in beats. 0.25=16th, 0.5=8th, 1=quarter.",
    "delayfeedback" => "Delay regen (0-0.95). High = long tails.",
    "shape"       => "Waveshaper drive (0-1). Subtle saturation at 0.1, heavy distortion at 0.5+.",
    "crush"       => "Bit-crush depth (1=destroyed, 16=clean). 6-8 = lofi.",
    "coarse"      => "Sample-rate reduction. Higher = chunkier aliasing.",
    "vowel"       => "Formant filter, vowels :a :e :i :o :u. Makes things 'speak'.",
    "enhance"     => "Mid/treble enhancer (0-1).",
    # Modulation
    "accelerate"  => "Pitch sweep across the note (semitones/sec). Positive = up, negative = down.",
    "vibrato"     => "Pitch wobble amount.",
    "tremolorate" => "Tremolo speed (Hz).",
    "tremolodepth"=> "Tremolo depth (0-1).",
    "phaserrate"  => "Phaser sweep speed (Hz).",
    "phaserdepth" => "Phaser depth (0-1).",
    # Pitch
    "octave"      => "Octave offset.",
    "detune"      => "Detune amount (cents/0-1).",
    "slide"       => "Pitch slide between notes.",
    # Sample window
    "begin"       => "Sample start position (0-1).",
    "end"         => "Sample end position (0-1).",
    "cut"         => "Cut group: voices sharing the same positive int truncate each other.",
    # --- COMMON SYNTHDEF PARAMS (used in our starter template + common conventions) ---
    "rate"        => "LFO rate in Hz. 4 = 4 cycles/sec, 0.5 = slow swell, 16 = fast wobble.",
    "depth"       => "Modulation depth. For an LFO on cutoff: how wide the cutoff sweeps around `centre`.",
    "centre"      => "Centre / pivot value an LFO modulates around. Used together with `depth` for symmetric sweeps.",
    "center"      => "Alias for centre. American spelling.",
    "q"           => "Filter resonance/quality (inverse 'rq'). 0.1=sharp peak, 0.5=medium, 1=no resonance. Higher q = more whistle.",
    "rq"          => "Reciprocal Q for SuperCollider filters (RLPF, RHPF). 1.0=no resonance, 0.1=very resonant.",
    "out"         => "Synth output bus number. 0=master left, 1=master right. SuperDirt routes through DirtPan via this.",
    "decay"       => "Decay time in sec. ADSR's D — how long from peak to sustain level.",
    "damp"        => "Damping (0-1). In reverbs: high freq absorption. In drums: sharpness of the body.",
    "mix"         => "Dry/wet mix for FX (0=dry, 1=wet).",
    "modfreq"     => "Modulator frequency for FM synthesis.",
    "moddepth"    => "Modulator depth / amplitude for FM.",
    "velocity"    => "Note velocity (0-1). Often shaped into amplitude or filter cutoff.",
    "threshold"   => "Compressor / gate threshold (typically in dB or amp 0-1).",
    "ratio"       => "Compressor ratio (1=no compression, 4=4:1, ∞=limiting).",
    "feedback"    => "Delay or comb feedback amount (0-0.95). High = long tails / oscillation.",
    "freqshift"   => "Frequency shifter amount (Hz, signed).",
    "pitchshift"  => "Pitch shifter amount (semitones).",
    "spread"      => "Stereo spread / detuning amount.",
    "fade"        => "Fade-in or crossfade time (sec).",
    "size"        => "Reverb size / room size (0-1). Larger = bigger virtual space.",
)

"""
    _PARAM_EXAMPLES

Maps the same names as `_PARAM_DOCS` to a list of one-line usage
examples surfaced by `:doc <name>`. Keep each line copy-pasteable —
the whole point is the user can drop it into the patterns pane and
press `e`. Not every entry needs examples; absence is fine.
"""
const _PARAM_EXAMPLES = Dict{String,Vector{String}}(
    "n" => [
        "@d1 :bd |> n(p\"0 3 5 0\")           # bd:0 bd:3 bd:5 bd:0 (sample variants)",
        "@d1 :wobble |> n(p\"0 3 7 12\") |> gain(0.7)   # root → m3 → fifth → octave",
        "@d1 :bass |> n(p\"<0 -5 7 -3>\")     # alternate the offset across cycles",
    ],
    "degree" => [
        "cps!(0.5); :scale minor",
        "@d1 :wobble |> degree(p\"0 2 4 7\") |> gain(0.6)  # scale-aware (no #s in mini-notation)",
    ],
    "gain" => [
        "@d1 p\"bd*4\" |> gain(0.8)",
        "@d1 p\"hh hh hh hh\" |> gain(p\"0.8 0.4 0.6 0.4\")  # accent pattern",
        "@d1 p\"sn\" |> gain(0.7) |> gain(1.4)             # composes ×, becomes 0.98",
    ],
    "pan" => [
        "@d1 p\"hh*8\" |> pan(p\"0.2 0.8\")    # ping-pong",
        "@d1 p\"bd\" |> pan(0.5)              # dead-center",
    ],
    "lpf" => [
        "@d1 p\"bd*4\" |> lpf(400)             # muffled kick",
        "@d1 :supersaw |> lpf(p\"<2000 800 4000>\")  # filter sweep across cycles",
    ],
    "hpf" => [
        "@d1 p\"oh*8\" |> hpf(6000) |> gain(0.5)   # tight click hat",
    ],
    "speed" => [
        "@d1 p\"bd*2\" |> speed(0.5)           # pitched down + slower",
        "@d1 p\"vinyl\" |> speed(p\"1 0.95 1 1.05\")  # turntable wow",
    ],
    "room" => [
        "@d1 p\"cp\" |> room(0.8) |> gain(0.6)",
    ],
    "delay" => [
        "@d1 p\"sn\" |> delay(0.6) |> delaytime(0.375) |> delayfeedback(0.5)",
    ],
    "cps" => [
        "cps!(0.5)        # 30 BPM at 4 beats/cycle, default",
        "cps!(0.75)       # ~45 BPM",
        ":bpm             # tap-tempo: 4 hits + Enter sets cps live",
    ],
    "fast" => [
        "@d1 p\"bd hh sn hh\" |> fast(2)        # twice as fast",
        "@d1 p\"bd hh\" |> every(4, fast(3))    # triplet every 4th cycle",
    ],
    "slow" => [
        "@d1 p\"bd sn cp ~\" |> slow(2)         # spread across 2 cycles",
    ],
    "every" => [
        "@d1 p\"bd hh sn hh\" |> every(4, rev)  # reverse every 4th cycle",
        "@d1 p\"bd hh sn hh\" |> every(3, fast(2))",
    ],
    "rev" => [
        "@d1 p\"bd hh sn hh\" |> rev            # hh sn hh bd",
    ],
    "stack" => [
        "@d1 stack(p\"bd*4\", p\"~ cp ~ cp\")     # layered drums",
    ],
    "cat" => [
        "@d1 cat([p\"bd*4\", p\"bd ~ bd ~\"])   # alternate beats each cycle",
    ],
    "mask" => [
        "@d1 mask(p\"bd*8\", p\"1 0 1 1 0 1 0 1\")  # gate the kicks",
    ],
    "" => [
        "@d1 p\"bd ~ sn ~\"            # 4 events per cycle",
        "@d1 p\"[bd bd] ~ sn ~\"       # nested = same time, two kicks",
        "@d1 p\"bd <hh sn cp> bd ~\"   # < > alternates each cycle",
    ],
    "gate" => [
        "@d1 gate(:bd, p\"1 0 1 0 1 0 1 0\")",
    ],
    "@dN" => [
        "@d1 p\"bd*4\"                  # slot d1",
        "@d2 p\"hh hh hh hh\" |> gain(0.4)",
        "# @d1 …                        # commented = muted, key `m` toggles",
    ],
)

"""
    _STARTER_PACKS

Genre starter sketches. Each value is a list of buffer lines that
replace the current buffer when the user runs `:starter <genre>`.
Keep each pack short (5-8 lines) — they're a starting point, not a
finished track.
"""
const _STARTER_PACKS = Dict{String,Vector{String}}(
    "house" => [
        "cps!(0.5)",
        "",
        "@d1 gate(:super808, p\"1 0 0 0 1 0 0 0 1 0 0 0 1 0 0 0\") |> n(-12) |> release(0.4) |> gain(1.4)",
        "@d2 gate(:supersnare, p\"0 0 0 0 1 0 0 0 0 0 0 0 1 0 0 0\") |> gain(0.9) |> room(0.2)",
        "@d3 p\"hh*8\" |> gain(0.35) |> hpf(4000) |> pan(p\"0.4 -0.4\")",
        "@d4 p\"superreese*2\" |> n(p\"-12 -7\") |> release(0.6) |> gain(1.0) |> lpf(800)",
    ],
    "witchhouse" => [
        "cps!(0.2)",
        "",
        "@d1 gate(:super808, p\"1 0 0 1 0 0 1 0\") |> n(-12) |> release(0.6) |> gain(1.6) |> room(0.3) |> shape(0.3)",
        "@d2 gate(:supersnare, p\"0 0 1 0\") |> n(-8) |> release(0.8) |> gain(0.7) |> room(0.7) |> lpf(2000)",
        "@d3 p\"hh*8\" |> speed(0.5) |> gain(0.4) |> hpf(3500) |> room(0.3)",
        "@d4 p\"superreese*4\" |> n(-24) |> release(0.8) |> gain(1.4) |> lpf(180) |> shape(0.5)",
        "@d5 p\"superhammond*2\" |> n(p\"-12 -5 -8 -3\") |> release(2.5) |> attack(0.5) |> gain(0.5) |> lpf(1200) |> room(0.6)",
    ],
    "ambient" => [
        "cps!(0.15)",
        "",
        "@d1 p\"superhammond\" |> n(p\"-12 -5 -8 -3 0 -3 -5 -8\") |> release(4.0) |> attack(1.0) |> gain(0.4) |> lpf(800) |> room(0.85) |> delay(0.4)",
        "@d2 p\"superfork\" |> n(p\"24 19 12 19 24 19 12 24\") |> release(3.0) |> gain(0.3) |> room(0.9)",
        "@d3 p\"supersine*1\" |> n(-36) |> release(8.0) |> gain(0.5) |> lpf(120) |> shape(0.2)",
    ],
    "trap" => [
        "cps!(0.4)",
        "",
        "@d1 gate(:super808, p\"1 0 0 1 0 0 0 1\") |> n(-12) |> release(0.5) |> gain(1.6)",
        "@d2 gate(:supersnare, p\"0 0 1 0\") |> gain(1.0) |> room(0.15)",
        "@d3 p\"hh*16\" |> gain(0.3) |> hpf(5000) |> pan(p\"0.3 -0.3 0.1 -0.1\")",
        "@d4 p\"super808\" |> n(p\"-24 -22 -19 -17\") |> release(1.0) |> gain(1.3) |> lpf(250) |> shape(0.4)",
    ],
    "lofi" => [
        "cps!(0.42)",
        "",
        "@d1 gate(:super808, p\"1 0 0 1\") |> gain(1.2) |> shape(0.3) |> lpf(2000)",
        "@d2 gate(:supersnare, p\"0 0 1 0\") |> gain(0.7) |> hpf(200) |> lpf(3000) |> room(0.4)",
        "@d3 p\"hh*4\" |> gain(0.3) |> hpf(2500) |> lpf(6000)",
        "@d4 p\"superhammond*2\" |> n(p\"0 -5 -8 -3\") |> release(1.5) |> gain(0.5) |> lpf(1800) |> room(0.5) |> crush(7)",
    ],

    # ── EDM expansion: cover the most-streamed subgenres that weren't
    # represented in the original 5 packs. Each pack still aims for
    # 5-7 lines — a starting point with kick + perc + bass + something
    # melodic, not a finished arrangement.
    "dubstep" => [
        "cps!(0.34)",   # ~140 BPM half-time feel",
        "",
        "@d1 gate(:super808, p\"1 0 0 0 0 0 0 0\") |> n(-12) |> release(0.6) |> gain(1.6)",
        "@d2 gate(:supersnare, p\"0 0 0 0 1 0 0 0\") |> gain(1.0) |> room(0.25) |> shape(0.2)",
        "@d3 p\"hh*8\" |> gain(0.25) |> hpf(5500) |> degradeBy(0.2)",
        "@d4 p\"superreese*2\" |> n(p\"<-12 -10 -8 -10>\") |> release(0.5) |> gain(1.4) |> lpf(p\"<400 1600 800 2400>\") |> shape(0.4)",
        "@d5 p\"~ ~ cp ~ ~ ~ cp ~\" |> gain(0.6) |> room(0.4)",
    ],
    "amapiano" => [
        "cps!(0.46)",   # ~112 BPM",
        "",
        "@d1 gate(:super808, p\"1 0 0 0 1 0 0 0\") |> n(-12) |> release(0.5) |> gain(1.4)",
        "@d2 p\"~ ~ cp ~ ~ ~ cp ~\" |> gain(0.7) |> room(0.3)",
        "@d3 p\"hh*16\" |> gain(0.3) |> hpf(4500) |> degradeBy(0.15)",
        "@d4 p\"superpiano*4\" |> n(p\"0 -3 5 7\") |> release(0.6) |> gain(0.55) |> room(0.4) |> degradeBy(0.3)",
        "@d5 :superreese |> n(p\"<-12 -10 -7 -5>\") |> release(0.8) |> gain(1.0) |> lpf(900) |> pump(8, 0.5)",
    ],
    "jungle" => [
        "cps!(0.7)",    # ~168 BPM",
        "",
        "@d1 p\"amen*2\" |> gain(1.2) |> speed(1.1) |> shape(0.2)",
        "@d2 gate(:super808, p\"1 0 0 0 0 0 1 0\") |> n(-12) |> release(0.5) |> gain(1.4)",
        "@d3 p\"~ ~ cp ~\" |> gain(0.6) |> room(0.4) |> shape(0.3)",
        "@d4 :superreese |> n(p\"-24 -19 -17 -12\") |> release(1.5) |> gain(1.0) |> lpf(p\"<500 1500>\")",
        "@d5 p\"hh*16\" |> gain(0.2) |> hpf(7000) |> degradeBy(0.3)",
    ],
    "idm" => [
        "cps!(0.55)",
        "",
        "@d1 p\"bd(3,8,<0 1 2>)\" |> gain(1.2)",
        "@d2 p\"cp(5,16,<2 4>)\" |> gain(0.7) |> room(0.3)",
        "@d3 p\"hh(11,16)\" |> gain(0.3) |> hpf(6000) |> degradeBy(0.4) |> pan(p\"<0 0.7 0.3 -0.5>\")",
        "@d4 :supersaw |> n(p\"0 7 5 ? 12 ?\") |> release(0.3) |> gain(0.6) |> lpf(p\"<300 1800 600>\") |> shape(0.3)",
        "@d5 p\"glitch ~ ~ glitch\" |> gain(0.5) |> sometimes(rev) |> crush(6)",
    ],
    "hardcore" => [
        "cps!(0.85)",   # 200+ BPM",
        "",
        "@d1 p\"k909*4\" |> gain(1.6) |> shape(0.6)",
        "@d2 gate(:supersnare, p\"0 0 1 0\") |> gain(1.2) |> room(0.2) |> shape(0.4)",
        "@d3 p\"hh*16\" |> gain(0.4) |> hpf(8000)",
        "@d4 :supersaw |> n(p\"<-12 -8 -5 -10>\") |> release(0.4) |> gain(1.3) |> lpf(p\"<400 2000 800>\") |> shape(0.5)",
        "@d5 p\"~ ~ ~ ~ cp ~ ~ ~\" |> gain(0.9) |> shape(0.4)",
    ],

    # ── Curated additions — common genre idioms documented in the
    #    TidalCycles tutorial (tidalcycles.org/docs, CC-BY-SA 4.0,
    #    Alex McLean et al.) and the AlgoRave community resources.
    #    Adapted to Ressac's combinator surface.
    "dub-techno" => [
        "# Dub techno — Basic Channel / Maurizio idiom",
        "# (long-decay delays + offset chord stab + minimal kick)",
        "cps!(0.5)",
        "",
        "@d1 p\"bd bd bd bd\" |> gain(1.0)",
        "@d2 p\"~ ~ cp ~\" |> gain(0.5) |> room(0.6)",
        "@d3 :supersaw |> n(p\"<-12 -10 -7>\") |> release(0.4) |> gain(0.45) |> lpf(900) |> delay(0.7) |> delaytime(0.5) |> delayfeedback(0.7) |> room(0.6)",
        "@d4 p\"hh ~ ~ ~ hh ~ ~ ~\" |> gain(0.3) |> hpf(6000)",
    ],
    "breakbeat" => [
        "# Breakbeat — classic 'Amen' chop idiom",
        "# (commonly taught in the Tidal tutorial as the breaks starter)",
        "cps!(0.56)",
        "",
        "@d1 p\"amencutup*4\" |> n(p\"<0 1 2 3 4 5>\") |> gain(1.2)",
        "@d2 gate(:super808, p\"1 0 0 0 0 0 0 0\") |> n(-12) |> release(0.4) |> gain(1.3)",
        "@d3 p\"~ ~ cp ~\" |> gain(0.7) |> room(0.3)",
        "@d4 :superreese |> n(p\"<-15 -12 -10>\") |> release(0.7) |> gain(0.8) |> lpf(p\"<600 1500>\")",
    ],
    "2step" => [
        "# UK 2-step garage — the syncopated kick + swung snare idiom",
        "# (Wookie/MJ Cole/Todd Edwards era, mid-90s UK)",
        "cps!(0.55)",
        "",
        "@d1 p\"bd ~ ~ bd ~ ~ bd ~\" |> gain(1.2)",
        "@d2 p\"~ ~ cp ~ ~ ~ ~ cp\" |> gain(0.8) |> room(0.3)",
        "@d3 p\"~ hh ~ hh ~ hh ~ hh\" |> gain(0.4) |> hpf(5000)",
        "@d4 :superpiano*2 |> n(p\"0 5 7 12\") |> release(0.3) |> gain(0.5) |> room(0.4)",
        "@d5 :superreese |> n(p\"<-12 -10 -7 -10>\") |> release(0.4) |> gain(0.7) |> lpf(800)",
    ],
)
