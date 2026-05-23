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
    "p"           => "p\"bd hh sn\" — mini-notation literal. Each whitespace-separated token = 1 event in the cycle.",
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
)
