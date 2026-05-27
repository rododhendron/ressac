# Live documentation: a thin always-visible row showing the doc of the
# word under the cursor (pattern side OR synth side). Pluto-notebook
# style. Also: a richer `:synth-guide` modal explaining how to write
# SuperCollider SynthDefs in the side panel.

"""
    _SC_UGEN_DOCS

SuperCollider UGen + method docs used by the live-doc widget when
the user's cursor is on a SCD identifier. Curated to the most useful
building blocks for the live SynthDef workflow.
"""
const _SC_UGEN_DOCS = Dict{String,String}(
    # Oscillators
    "SinOsc"     => "SinOsc.ar(freq, phase=0, mul=1, add=0) — pure sine wave. Use for sub bass, fundamental tones.",
    "Saw"        => "Saw.ar(freq) — bandlimited sawtooth. Harmonics-rich, classic synth lead/bass material.",
    "Pulse"      => "Pulse.ar(freq, width=0.5) — square/pulse wave with adjustable duty cycle.",
    "LFTri"      => "LFTri.ar(freq) — non-bandlimited triangle. Light, hollow tone.",
    "VarSaw"     => "VarSaw.ar(freq, iphase=0, width=0.5) — saw with variable shape.",
    "Blip"       => "Blip.ar(freq, numharm=200) — band-limited impulse, harmonics-controlled.",
    "WhiteNoise" => "WhiteNoise.ar(mul=1) — flat-spectrum noise.",
    "PinkNoise"  => "PinkNoise.ar(mul=1) — natural-sounding noise (-3dB/oct).",
    "BrownNoise" => "BrownNoise.ar(mul=1) — deep rumble noise (-6dB/oct).",
    "Dust"       => "Dust.ar(density) — random impulses per sec.",
    # LFOs (control-rate)
    "LFSaw"      => "LFSaw.kr(freq) — low-frequency saw, for modulation.",
    "LFNoise0"   => "LFNoise0.kr(freq) — stepped random LFO.",
    "LFNoise1"   => "LFNoise1.kr(freq) — linear-interpolated random LFO.",
    "LFNoise2"   => "LFNoise2.kr(freq) — quadratic-interpolated random LFO.",
    "LFPulse"    => "LFPulse.kr(freq) — square LFO.",
    # Filters
    "LPF"        => "LPF.ar(in, freq) — second-order lowpass.",
    "RLPF"       => "RLPF.ar(in, freq, rq) — resonant lowpass (rq = 1/Q, 0=open, 1=no resonance).",
    "HPF"        => "HPF.ar(in, freq) — highpass filter.",
    "RHPF"       => "RHPF.ar(in, freq, rq) — resonant highpass.",
    "BPF"        => "BPF.ar(in, freq, rq) — bandpass.",
    "MoogFF"     => "MoogFF.ar(in, freq, gain=2) — 4-pole Moog ladder filter, has self-oscillation.",
    "Resonz"     => "Resonz.ar(in, freq, bwr=1) — narrow resonator.",
    # Envelopes
    "EnvGen"     => "EnvGen.kr(env, gate=1, doneAction:0) — envelope generator. doneAction:2 frees the synth at end.",
    "Env"        => "Env(levels, times, curves) / Env.adsr(a,d,s,r) / Env.linen(a,sus,r) / Env.perc(a,r) — envelope shape.",
    "Line"       => "Line.kr(start, end, dur) — linear ramp.",
    "XLine"      => "XLine.kr(start, end, dur) — exponential ramp (start must be non-zero).",
    # Routing / output
    "Out"        => "Out.ar(bus, sig) — write to an audio bus.",
    "OffsetOut"  => "OffsetOut.ar(bus, sig) — sample-accurate output. Use in SuperDirt synths.",
    "Pan2"       => "Pan2.ar(in, pos=0) — stereo panner, pos -1..1.",
    "DirtPan"    => "DirtPan.ar(sig, numChans, pan) — SuperDirt-aware panner that handles routing.",
    "ReplaceOut" => "ReplaceOut.ar(bus, sig) — overwrite the bus (effects pipelines).",
    # FX
    "FreeVerb"   => "FreeVerb.ar(in, mix=0.33, room=0.5, damp=0.5) — simple stereo reverb.",
    "JPverb"     => "JPverb.ar(in, t60=1, damp=0, size=1) — high-quality reverb.",
    "DelayN"     => "DelayN.ar(in, maxdelay, delay) — uninterpolated delay.",
    "DelayC"     => "DelayC.ar(in, maxdelay, delay) — cubic-interpolated delay.",
    "CombC"      => "CombC.ar(in, maxdelay, delay, decay) — comb-filter delay.",
    "AllpassC"   => "AllpassC.ar(in, maxdelay, delay, decay) — allpass delay (reverb building block).",
    "Decimator"  => "Decimator.ar(in, rate=44100, bits=24) — bit/sample-rate reducer (lofi).",
    # Math / shaping
    "tanh"       => "method .tanh — saturate input via hyperbolic tangent. Good cheap distortion.",
    "clip"       => "method .clip(lo, hi) — hard-clip the value.",
    "fold"       => "method .fold(lo, hi) — wave folding.",
    "wrap"       => "method .wrap(lo, hi) — wrap modulo.",
    "range"      => "method .range(lo, hi) — remap a -1..1 signal to lo..hi.",
    # Common syntax
    "SynthDef"   => "SynthDef(\\name, { |params| ... }).add — register a synth graph. Params become OSC keys.",
    "doneAction" => "Envelope completion action. 0=do nothing, 2=free this synth (use to auto-cleanup).",
    "ar"         => "method .ar — audio-rate UGen output (44.1 kHz). Use for the audible signal path.",
    "kr"         => "method .kr — control-rate UGen output (~700 Hz). Use for modulation/envelopes — cheaper.",
    "add"        => "method .add — register the SynthDef with the local server (~scsynth).",
    "play"       => "method .play — start a Routine or Pattern.",
    "interpret"  => "String method — eval the contents as sclang. Used by /dirt/evalSC to install synthdefs.",
)

"""
    _SYNTH_GUIDE_LINES

Long-form guide opened by `:synth-guide`. Same modal mechanism as
`:guide` (j/k scroll, q close, / search).
"""
const _SYNTH_GUIDE_LINES = String[
    "── Writing a SynthDef in Ressac — quick guide ──",
    "",
    "1. Open the side panel:    :synth mywob",
    "   The right pane loads a starter SynthDef template you can edit.",
    "",
    "2. Hear it:                  T  (or :test)",
    "   Plays the synth as it'd sound in a pattern (SuperDirt-controlled",
    "   freq/sustain/gain). Match what `@d1 p\"mywob\"` will produce.",
    "",
    "3. Hear raw defaults:        :test-raw",
    "   Plays the synth with NO SuperDirt overrides — your `freq = 220`,",
    "   `gain = 0.5`, `release = 0.4` etc. defaults are active.",
    "",
    "4. Iterate:                  edit → T → edit → T → ...",
    "   The server-side s.sync ensures the new SynthDef is registered",
    "   before each play, so every press fires the latest version.",
    "",
    "5. Save:                     :save-synth        (overwrites current)",
    "                              :save-synth-as newname  (fork to a new file)",
    "   Persists to plugins/user-synths/<name>.scd and registers a",
    "   :synth entry so the browser + autocomplete see it.",
    "",
    "── SynthDef anatomy ──",
    "",
    "SynthDef(\\name, { |out, pan = 0, freq = 220, sustain = 1, gain = 0.5,",
    "                  attack = 0.01, release = 0.4,",
    "                  rate = 4, cutoff = 800, q = 0.3|",
    "    var lfo, osc, filt, env, sig;",
    "    lfo  = SinOsc.kr(rate).range(cutoff - 600, cutoff + 600);",
    "    osc  = Saw.ar(freq);",
    "    filt = RLPF.ar(osc, lfo, q);",
    "    env  = EnvGen.kr(Env.linen(attack, sustain, release), doneAction: 2);",
    "    sig  = filt * env * gain;",
    "    OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));",
    "}).add;",
    "",
    "Params in the |...| list:",
    "  - become OSC keys you drive from Ressac (set(:rate, 8) etc.)",
    "  - SuperDirt always overrides freq/sustain/gain — those defaults are",
    "    only audible with :test-raw. Everything else (cutoff/rate/q/...)",
    "    is heard via T and stays under your control in patterns too.",
    "",
    "── Common UGens to know ──",
    "",
    "Oscillators (audio-rate, build the tone):",
    "  SinOsc.ar(freq)   sine — pure, sub-bass-ready",
    "  Saw.ar(freq)      saw — bright, harmonics-rich (good leads/bass)",
    "  Pulse.ar(freq, w) square/pulse — w controls duty cycle",
    "  LFNoise1.ar(freq) random noise interpolated",
    "",
    "LFOs (control-rate, modulate other params):",
    "  SinOsc.kr(rate).range(lo, hi)   — smooth swing between lo and hi",
    "  LFNoise1.kr(rate).range(lo, hi) — random walk",
    "",
    "Filters:",
    "  LPF.ar(in, freq)         — lowpass, smoothly cuts highs",
    "  RLPF.ar(in, freq, rq)    — resonant lowpass (lower rq = more resonance)",
    "  HPF.ar(in, freq)         — highpass, removes low rumble",
    "  MoogFF.ar(in, freq, 2)   — Moog ladder, can self-oscillate",
    "",
    "Envelopes (shape volume over time):",
    "  EnvGen.kr(Env.perc(0.01, 0.5))            — short percussive",
    "  EnvGen.kr(Env.linen(att, sustain, rel))   — full ADSR-ish",
    "  EnvGen.kr(Env.adsr(att, dec, sus, rel))   — full ADSR",
    "  Always set `doneAction: 2` so the synth frees itself at the end.",
    "",
    "Routing:",
    "  OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan))",
    "  ↑ standard SuperDirt output line — stereo, sample-accurate, pannable.",
    "",
    "── Tips for a junior sound designer ──",
    "",
    "Start small:   one oscillator + one envelope. Get a clean note first.",
    "Then add LPF:  `RLPF.ar(osc, cutoff)`. Lower cutoff = darker.",
    "Then modulate: LFO on cutoff for movement.",
    "Then distort:  `.tanh` or `(sig * 2).clip(-1,1)` for grit.",
    "Then reverb:   `FreeVerb.ar(sig, 0.3, 0.7)` if you don't want to use",
    "               SuperDirt's room send.",
    "",
    "Workflow:",
    "  1. :synth myname        — open editor with template",
    "  2. T                     — hear it",
    "  3. tweak one line at a time, T after each tweak",
    "  4. :test-raw             — sanity-check that param defaults take effect",
    "  5. happy?  :save-synth   — persist + register",
    "  6. swap to patterns (Tab) and use it: @d1 p\"myname\" |> n(-12)",
    "",
    "── Examples ──",
    "",
    "Sub bass (clean, deep):",
    "  SinOsc.ar(freq) * EnvGen.kr(Env.linen(0.005, sustain, 0.05), doneAction:2)",
    "",
    "Wobble bass (LFO on cutoff):",
    "  RLPF.ar(Saw.ar(freq), SinOsc.kr(4).range(200, 2000), 0.3)",
    "",
    "Pad (slow attack, soft):",
    "  Mix(SinOsc.ar([freq, freq*1.005, freq*0.995])) * EnvGen.kr(Env.linen(0.5, sustain, 1.5))",
    "",
    "Press q or Esc to close this guide.",
]

"""
    _GUIDE_LINES

Top-level keybinding cheat-sheet, opened by `:guide` / `?` / `Space ?`.
j/k scroll, q close, / search.
"""
const _GUIDE_LINES = String[
    "── Ressac guide ── (j/k scroll, q close)",
    "",
    "▓ MODES",
    "  i / a / o / O    — enter insert mode (vim conventions)",
    "  Esc              — back to normal mode",
    "  :                — command mode (ex-command)",
    "",
    "▓ NORMAL-MODE ACTIONS",
    "  hjkl / arrows    — move cursor",
    "  0 / \$            — line start / end",
    "  gg / G           — buffer start / end",
    "  e                — eval current line (patterns pane only)",
    "  m                — mute / unmute @dN slot under cursor",
    "  K                — preview sample/synth under cursor",
    "  t  /  T  /  Space — test the synth (synth pane only)",
    "                     hold to repeat-fire (accelerates up to ~17 Hz)",
    "  S                — cycle scope: off → amp → wave → spectrum",
    "  !                — PANIC (kill all)   ·   ,   — hush (soft stop)",
    "  Tab              — swap focus between patterns / synth pane",
    "  gt / gT          — next / previous synth tab",
    "",
    "▓ NUDGE NUMBERS (cursor on a number literal)",
    "  +  /  -          — ±1   (or ±1.0 for floats)",
    "  *  /  /          — ±10  (or ±0.1 for floats)",
    "  hold to scrub continuously",
    "",
    "▓ SCOPE ZOOM (when scope is :wave)",
    "  + / -            — Y-zoom (amplitude)",
    "  > / <            — X-zoom (time window)",
    "  =                — reset both",
    "",
    "▓ PATTERNS — mini-notation inside p\"...\"",
    "  p\"bd hh sn hh\"     — 4-step sequence (one bar)",
    "  p\"bd ~ sn ~\"       — `~` is a rest",
    "  p\"[bd hh] sn\"      — group inside one slot (subdivide)",
    "  p\"<bd sn cp>\"      — alternate, one per cycle",
    "  p\"bd*4\"            — repeat in time (4 hits in one slot)",
    "  p\"bd!3\"            — repeat in slot (3 separate slots)",
    "  p\"bd(3,8)\"         — Euclidean rhythm: 3 beats over 8 steps",
    "  p\"bd:2\"            — variant index (e.g. bd bank #2)",
    "  combine: p\"<[bd*2] sn> ~ bd ~\"",
    "",
    "▓ EFFECT CHAIN (pipe operator |>)",
    "  @d1 p\"bd hh\" |> gain(0.8) |> lpf(2000) |> pan(0.3)",
    "  gain / speed / lpf / hpf / pan / n / room / delay / shape / set",
    "  gain × | lpf min | hpf max | speed × | rest overwrite",
    "",
    "▓ EX-COMMANDS (:prefix)",
    "  :q                   — quit",
    "  :cps <x>             — set tempo (cycles per second)",
    "  :synth <name>        — open synth in tab (creates if absent)",
    "  :lib                 — synth library picker (built-in + user)",
    "  :sccode  /  :sc      — browse sccode.org",
    "  :sccode <id>         — import one sccode entry directly",
    "  :sccode-tag <tag>    — browse sccode by tag",
    "  :browse              — sample / instrument / synth browser",
    "  :doc <name>          — show docstring + usage examples",
    "  :scale <name>        — set the active scale for degree()",
    "  :starter <genre>     — load a genre starter pack",
    "  :mute dN / :unmute dN / :solo dN",
    "  :scope amp|wave|spectrum|off",
    "  :theme <name>        — switch theme",
    "  :reload-config       — reload ./ressac.toml",
    "  :hush / :panic       — stop everything (soft / nuclear)",
    "  :safety on|off       — master limiter + DC block + 10Hz HPF",
    "  :wiki / :guide       — in-app wiki / this cheat sheet",
    "  :dsl                 — synth DSL guide & cookbook",
    "  :snip / :snippets    — searchable snippet picker (Enter inserts)",
    "  :pause               — freeze render to copy text",
    "  :keydebug            — log every keypress",
    "  :copylogs            — send log buffer to system clipboard",
    "",
    "▓ SESSIONS & FILES",
    "  :save <name>         — save current patterns buffer to sessions/<name>.txt",
    "  :load <name>         — load a saved session into the patterns pane",
    "  :sessions            — list saved sessions  (Tab on :load completes names)",
    "  After :load you still need to press E to eval everything.",
    "",
    "▓ TAP-TO-PATTERN",
    "  :tap [sample]        — tap a rhythm, Enter commits as @dN p\"…\"",
    "                         auto-detects loop period, sets cps, evals.",
    "  :tap-strict [sample] — same but no loop detection (single-bar quantize)",
    "  :bpm / :tap-tempo    — tap 2+ beats to set cps directly",
    "  :piano [synth]       — keyboard plays chromatic semitones",
    "  :piano-rec [synth]   — same + records hits into a @dN line",
    "",
    "▓ SYNTH PANE",
    "  :w / :w <newname>    — save (Save-As opens new tab)",
    "  :close / :back       — close tab / exit synth pane",
    "  :tabs                — list open synth tabs",
    "  T (held)             — fire the synth, hold to repeat-fire",
    "",
    "Tab in insert: cycle through autocompletion candidates",
    "Tab in :   : autocompletes the ex-command verb or argument",
]

# ---------------------------------------------------------------------
# Live-doc widget
# ---------------------------------------------------------------------

"""
    _word_under_cursor(line, col) -> String

Extract the identifier-like word at byte position `col` in `line`.
More permissive than the autocomplete extractor: allows `.method`
chains so `SinOsc.ar` is one token (then we split if needed).
"""
function _word_under_cursor(line::AbstractString, col::Integer)
    isempty(line) && return ""
    n = lastindex(line)
    col = clamp(col, 1, n)
    # Walk backward while the char is identifier-ish (letters/digits/_/.).
    start_col = col
    while start_col > 1
        prev = prevind(line, start_col)
        prev >= 1 && _is_ugen_char(line[prev]) || break
        start_col = prev
    end
    end_col = col - 1
    j = col
    while j <= n && _is_ugen_char(line[j])
        end_col = j
        j = nextind(line, j)
    end
    end_col < start_col && return ""
    return String(line[start_col:end_col])
end

_is_ugen_char(c::AbstractChar) =
    isletter(c) || isdigit(c) || c == '_' || c == '.'

"""
    _lookup_livedoc(word) -> Union{Nothing, String}

Try `_DOCS` registry first (covers params, combinators, mini-notation,
plus everything plugins ship under `[docs]`), then `_SC_UGEN_DOCS` (SC
UGens), then strip a `.method` suffix and try the head. Returns
`nothing` if no entry.
"""
function _lookup_livedoc(word::AbstractString)
    isempty(word) && return nothing
    e = lookup_doc(String(word))
    e !== nothing && return e.short
    doc = get(_SC_UGEN_DOCS, String(word), nothing)
    doc !== nothing && return doc
    if occursin('.', word)
        head, _ = split(word, '.'; limit=2)
        doc = get(_SC_UGEN_DOCS, String(head), nothing)
        doc !== nothing && return doc
        e_head = lookup_doc(String(head))
        e_head !== nothing && return e_head.short
        _, tail = split(word, '.'; limit=2)
        doc = get(_SC_UGEN_DOCS, String(tail), nothing)
        doc !== nothing && return doc
    end
    return nothing
end

"""
    _livedoc_line(m)

A single-row widget showing the live doc for the word under the
cursor. Empty when no doc is found. Always rendered between footer
and logs so the user has docs at a glance.
"""
# `_LivedocLine` widget + `_livedoc_line(::LiveModel)` builder both
# removed in phase-3 cleanup. The RessacApp path renders livedoc
# inline via the editor's hint strip (see `app.jl`).
# `_word_under_cursor` + `_lookup_livedoc` (defined above) are the
# pure helpers it shares with the deleted widget.
