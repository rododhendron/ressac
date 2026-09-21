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
    "Dust2"      => "Dust2.ar(density) — bipolar (-1..1) random impulses.",
    "GrayNoise"  => "GrayNoise.ar(mul=1) — flat noise via bit-flipping; cheaper than WhiteNoise.",
    "ClipNoise"  => "ClipNoise.ar(mul=1) — sample-and-hold +1/-1 noise (extreme harsh).",
    "Crackle"    => "Crackle.ar(chaosParam=1.5, mul=1) — chaotic noise via x_{n+1} = abs(c·x_n − x_{n-1}).",
    "Impulse"    => "Impulse.ar/.kr(freq, phase=0) — non-bandlimited single-sample impulse train.",
    "Formant"    => "Formant.ar(fundfreq, formfreq, bwfreq) — formant-shaped oscillator.",
    "Klang"      => "Klang.ar(specificationsArrayRef, freqscale=1, freqoffset=0) — bank of fixed sine oscs.",
    # Chaos generators
    "LorenzL"    => "LorenzL.ar(freq, s=10, r=28, b=2.667) — Lorenz attractor (linear).",
    "HenonC"     => "HenonC.ar(freq, a=1.4, b=0.3) — Hénon map (cubic interp).",
    "LogisticN"  => "LogisticN.ar(chaosParam=3.0, freq=1000) — logistic map x' = c·x·(1−x).",
    "StandardN"  => "StandardN.ar(freq, k=1.0) — Chirikov standard map.",
    "LatoocarfianC" => "LatoocarfianC.ar(freq, a=1, b=3, c=0.5, d=0.5) — Latoocarfian (Pickover) attractor.",
    "LinCongC"   => "LinCongC.ar(freq, a=1.1, c=0.13, m=1.0) — linear congruential generator.",
    "QuadC"      => "QuadC.ar(freq, a=1.0, b=-1.0, c=-0.75) — quadratic map.",
    "FBSineC"    => "FBSineC.ar(freq, im=1, fb=0.1, a=1.1, c=0.5) — feedback sine.",
    "GbmanC"     => "GbmanC.ar(freq) — Gingerbreadman attractor.",
    "CuspC"      => "CuspC.ar(freq, a=1.0, b=1.9) — cusp catastrophe map.",
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
    # Envelopes — generic + per-shape
    "EnvGen"     => "EnvGen.kr(env, gate=1, doneAction:0) — envelope generator. doneAction:2 frees the synth at end.",
    "Env"        => "Env(levels, times, curves) — generic envelope spec. See Env.<shape> for the named presets.",
    "Env.adsr"   => "Env.adsr(attack, decay, sustainLevel, release, peak=1, curve=-4) — classic attack/decay/sustain/release; gated.",
    "Env.asr"    => "Env.asr(attack, sustainLevel, release, curve=-4) — attack/sustain/release; gated, no decay phase.",
    "Env.dadsr"  => "Env.dadsr(delay, attack, decay, sustainLevel, release, peak=1, curve=-4) — adsr preceded by a silent delay.",
    "Env.perc"   => "Env.perc(attack, release, level=1, curve=-4) — percussive: rise to level then exp decay. No sustain.",
    "Env.linen"  => "Env.linen(attack, sustain, release, level=1, curve=:lin) — linear ramp up, hold, ramp down. Length = a+s+r.",
    "Env.sine"   => "Env.sine(dur, level=1) — half-sine bump over `dur` seconds.",
    "Env.cutoff" => "Env.cutoff(release, level=1, curve=:lin) — sustain until gate, then fade over `release`.",
    "Env.pairs"  => "Env.pairs([[time,level], …], curve=:lin) — breakpoint envelope from (time, level) tuples.",
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
    "DelayL"     => "DelayL.ar(in, maxdelay, delay) — linearly-interpolated delay.",
    "CombN"      => "CombN.ar(in, maxdelay, delay, decay) — uninterpolated comb delay.",
    "CombL"      => "CombL.ar(in, maxdelay, delay, decay) — linear-interp comb delay.",
    "AllpassN"   => "AllpassN.ar(in, maxdelay, delay, decay) — uninterpolated allpass delay.",
    "AllpassL"   => "AllpassL.ar(in, maxdelay, delay, decay) — linear-interp allpass delay.",
    "Allpass"    => "Allpass.ar(in, ...) — generic allpass family (use AllpassC/L/N for concrete).",
    "GVerb"      => "GVerb.ar(in, roomsize=10, revtime=3, damping=0.5) — modeled-room reverb.",
    "Decay"      => "Decay.ar(in, decayTime=1.0) — exp decay of impulses; turns triggers into envelopes.",
    "Decay2"     => "Decay2.ar(in, attackTime=0.01, decayTime=1.0) — Decay with attack ramp; no click.",
    # Filters extras
    "BRF"        => "BRF.ar(in, freq, rq) — band-reject (notch) filter.",
    "LeakDC"     => "LeakDC.ar(in, coef=0.995) — strip DC offset from an audio signal.",
    "Median"     => "Median.ar(length, in) — median of last `length` samples; removes spikes.",
    "Slope"      => "Slope.kr(in) — sample-to-sample slope (derivative) of the input.",
    "Ramp"       => "Ramp.kr(in, lagTime) — single-sample linear ramp toward each new input value.",
    "Lag"        => "Lag.kr(in, lagTime=0.1) — exp smoothing (RC lag) — softens parameter jumps.",
    "Lag2"       => "Lag2.kr(in, lagTime=0.1) — two cascaded Lags; smoother than Lag.",
    "Lag3"       => "Lag3.kr(in, lagTime=0.1) — three cascaded Lags; smoothest.",
    "BLowPass"   => "BLowPass.ar(in, freq=1200, rq=1) — biquad lowpass.",
    "BHiPass"    => "BHiPass.ar(in, freq=1200, rq=1) — biquad highpass.",
    "BPeakEQ"    => "BPeakEQ.ar(in, freq=1200, rq=1, db=0) — biquad peaking EQ.",
    "BLowShelf"  => "BLowShelf.ar(in, freq=1200, rs=1, db=0) — biquad low shelf.",
    "BHiShelf"   => "BHiShelf.ar(in, freq=1200, rs=1, db=0) — biquad high shelf.",
    # LFO extras
    "LFCub"      => "LFCub.kr(freq) — cubic-interpolated quasi-sine LFO.",
    "LFPar"      => "LFPar.kr(freq) — parabolic LFO (smoother than triangle).",
    # Spatial extras
    "LinPan2"    => "LinPan2.ar(in, pos=0) — linear stereo pan (no power compensation).",
    "Balance2"   => "Balance2.ar(left, right, pos=0, level=1) — fade between two channels.",
    "Rotate2"    => "Rotate2.ar(xIn, yIn, pos=0) — rotate a stereo image in the plane.",
    "Splay"      => "Splay.ar(inArray, spread=1, level=1, center=0) — spread N signals across stereo.",
    "Mix"        => "Mix(array) — sum every signal in `array` into a single channel.",
    # Triggers / pitch
    "Trig"       => "Trig.kr(in, dur=0.1) — emit a high value for `dur` on rising edge.",
    "TDelay"     => "TDelay.kr(in, dur) — re-emit triggers delayed by `dur` seconds.",
    "PitchShift" => "PitchShift.ar(in, windowSize=0.2, pitchRatio=1, …) — granular pitch shifter.",
    "FreqShift"  => "FreqShift.ar(in, freq=0, phase=0) — single-sideband frequency shifter.",
    "Vibrato"    => "Vibrato.ar(freq=440, rate=6, depth=0.02, delay=0) — built-in vibrato oscillator.",
    # Buffers
    "PlayBuf"    => "PlayBuf.ar(numChannels, bufnum, rate=1, trigger=1, startPos=0, loop=0, doneAction=0) — sample playback.",
    "BufRd"      => "BufRd.ar(numChannels, bufnum, phase=0, loop=1, interpolation=2) — read a buffer at an arbitrary phase.",
    "GrainBuf"   => "GrainBuf.ar(numChannels, trigger, dur, sndbuf, rate=1, pos=0, interp=2, pan=0, envbufnum=-1, maxGrains=512) — granular playback.",
    "Warp1"      => "Warp1.ar(numChannels, bufnum, pointer=0, freqScale=1, windowSize=0.2, envbufnum=-1, overlaps=8, …) — multi-grain time/pitch warp.",
    # Rate conversion
    "A2K"        => "A2K.kr(in) — audio-rate → control-rate (decimate).",
    "K2A"        => "K2A.ar(in) — control-rate → audio-rate (upsample).",
    # Math / shaping
    "tanh"        => "method .tanh — saturate input via hyperbolic tangent. Good cheap distortion.",
    "Tanh"        => "Tanh.ar(in) — UGen wrapper for .tanh; soft saturator, classic drive.",
    "SoftClipper" => "SoftClipper.ar(in) — quadratic soft clip — less harmonics than tanh.",
    "CubicDistort"=> "CubicDistort.ar(in) — cubic transfer function for asymmetric drive.",
    "Clip"        => "Clip.ar(in, lo=-1, hi=1) — UGen wrapper for .clip(lo, hi).",
    "Fold"        => "Fold.ar(in, lo=-1, hi=1) — UGen wrapper for .fold; wave folder.",
    "Wrap"        => "Wrap.ar(in, lo=-1, hi=1) — UGen wrapper for .wrap; modulo wrap.",
    "clip"        => "method .clip(lo, hi) — hard-clip the value.",
    "fold"        => "method .fold(lo, hi) — wave folding.",
    "wrap"        => "method .wrap(lo, hi) — wrap modulo.",
    "range"       => "method .range(lo, hi) — remap a -1..1 signal to lo..hi.",
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
`:dsl` (j/k défiler, q fermer).
"""
const _SYNTH_GUIDE_LINES = String[
    "── Écrire un SynthDef dans Ressac — guide rapide ──",
    "",
    "1. Ouvre une pane synth :         :synth mywob",
    "   Elle charge un SynthDef de départ que tu peux éditer.",
    "",
    "2. Écoute-le :                    T  (ou :test)",
    "   Joue le synth comme il sonnera dans un pattern (freq/sustain/gain",
    "   pilotés par SuperDirt) — ce que produira `@d1 p\"mywob\"`.",
    "",
    "3. Écoute ses valeurs par défaut : :test-raw",
    "   Sans aucun override SuperDirt — tes `freq = 220`, `gain = 0.5`,",
    "   `release = 0.4` etc. sont actifs.",
    "",
    "4. Itère :                        édite → T → édite → T → …",
    "   Le s.sync côté serveur garantit que le nouveau SynthDef est",
    "   enregistré avant chaque lecture : chaque T joue la dernière version.",
    "",
    "5. Sauve :                        :w            (écrase le fichier courant)",
    "                                   :w nouveaunom  (fork dans un nouveau fichier)",
    "   Écrit plugins/user-synths/<nom>.scd et enregistre une entrée :synth",
    "   visible dans la librairie et la complétion. U l'utilise dans un pattern.",
    "",
    "── Anatomie d'un SynthDef ──",
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
    "Les paramètres de la liste |...| :",
    "  - deviennent des clés OSC pilotables depuis Ressac (set(:rate, 8) etc.)",
    "  - SuperDirt écrase toujours freq/sustain/gain — leurs défauts ne",
    "    s'entendent qu'avec :test-raw. Le reste (cutoff/rate/q/…) s'entend",
    "    avec T et reste sous ton contrôle dans les patterns.",
    "",
    "── UGens à connaître ──",
    "",
    "Oscillateurs (audio, la matière) :",
    "  SinOsc.ar(freq)   sinus — pur, parfait pour le sub",
    "  Saw.ar(freq)      dent-de-scie — brillante, riche en harmoniques (leads, basses)",
    "  Pulse.ar(freq, w) carrée/pulse — w règle le rapport cyclique",
    "  LFNoise1.ar(freq) bruit aléatoire interpolé",
    "",
    "LFOs (contrôle, modulent d'autres paramètres) :",
    "  SinOsc.kr(rate).range(lo, hi)   — balancement doux entre lo et hi",
    "  LFNoise1.kr(rate).range(lo, hi) — marche aléatoire",
    "",
    "Filtres :",
    "  LPF.ar(in, freq)         — passe-bas, coupe doucement les aigus",
    "  RLPF.ar(in, freq, rq)    — passe-bas résonant (rq bas = plus de résonance)",
    "  HPF.ar(in, freq)         — passe-haut, enlève le grondement grave",
    "  MoogFF.ar(in, freq, 2)   — échelle Moog, peut auto-osciller",
    "",
    "Enveloppes (le volume dans le temps) :",
    "  EnvGen.kr(Env.perc(0.01, 0.5))            — percussive courte",
    "  EnvGen.kr(Env.linen(att, sustain, rel))   — quasi ADSR",
    "  EnvGen.kr(Env.adsr(att, dec, sus, rel))   — ADSR complète",
    "  Mets toujours `doneAction: 2` pour que le synth se libère à la fin.",
    "",
    "Routage :",
    "  OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan))",
    "  ↑ la sortie SuperDirt standard — stéréo, précise à l'échantillon, pannable.",
    "",
    "── Conseils pour débuter en design sonore ──",
    "",
    "Commence petit : un oscillateur + une enveloppe. Une note propre d'abord.",
    "Puis un LPF :   `RLPF.ar(osc, cutoff)`. Cutoff bas = plus sombre.",
    "Puis module :   un LFO sur le cutoff pour du mouvement.",
    "Puis sature :   `.tanh` ou `(sig * 2).clip(-1,1)` pour du grain.",
    "Puis réverb :   `FreeVerb.ar(sig, 0.3, 0.7)` si tu ne veux pas passer",
    "                par le send room de SuperDirt.",
    "",
    "Boucle de travail :",
    "  1. :synth monnom         — ouvre l'éditeur avec le modèle",
    "  2. T                     — écoute",
    "  3. change une ligne à la fois, T après chaque changement",
    "  4. :test-raw             — vérifie que les défauts des paramètres portent",
    "  5. content ?  :w         — sauve + enregistre",
    "  6. U                     — l'utilise dans un pattern (ou Tab puis @d1 p\"monnom\")",
    "",
    "── Exemples ──",
    "",
    "Sub (propre, profond) :",
    "  SinOsc.ar(freq) * EnvGen.kr(Env.linen(0.005, sustain, 0.05), doneAction:2)",
    "",
    "Wobble (LFO sur le cutoff) :",
    "  RLPF.ar(Saw.ar(freq), SinOsc.kr(4).range(200, 2000), 0.3)",
    "",
    "Nappe (attaque lente, douce) :",
    "  Mix(SinOsc.ar([freq, freq*1.005, freq*0.995])) * EnvGen.kr(Env.linen(0.5, sustain, 1.5))",
    "",
    "q ou Esc ferme ce guide.",
]

"""
    _GUIDE_REFERENCE_LINES

Partie « référence » de l'aide `?` (après les sections de touches, qui
sont générées depuis le registre) : mini-notation, chaîne d'effets,
commandes ex, sessions, tap/piano.
"""
const _GUIDE_REFERENCE_LINES = String[
    "",
    "▓ MINI-NOTATION dans p\"…\"",
    "  p\"bd hh sn hh\"     — séquence de 4 pas (une mesure)",
    "  p\"bd ~ sn ~\"       — `~` est un silence",
    "  p\"[bd hh] sn\"      — groupe dans un pas (subdivise)",
    "  p\"<bd sn cp>\"      — alterne, un par cycle",
    "  p\"bd*4\"            — répète dans le temps (4 coups dans un pas)",
    "  p\"bd!3\"            — répète le pas (3 pas séparés)",
    "  p\"bd(3,8)\"         — rythme euclidien : 3 coups sur 8 pas",
    "  p\"bd:2\"            — variante (ex. banque bd n°2)",
    "  combiner : p\"<[bd*2] sn> ~ bd ~\"",
    "",
    "▓ CHAÎNE D'EFFETS (opérateur |>)",
    "  @d1 p\"bd hh\" |> gain(0.8) |> lpf(2000) |> pan(0.3)",
    "  gain / speed / lpf / hpf / pan / n / room / delay / shape / set",
    "  gain × | lpf min | hpf max | speed × | le reste écrase",
    "",
    "▓ COMMANDES (:)",
    "  :q                   — quitter",
    "  :cps <x>             — tempo (cycles par seconde)",
    "  :synth <nom>         — ouvre le synth dans une pane (le crée s'il n'existe pas)",
    "  :lib                 — librairie de synths (intégrés + utilisateur)",
    "  :sculpt [nom]        — sculpter un synth DSL (knobs sur l'onde)",
    "  :vsplit explorer     — explorateur génétique de synths",
    "  :sccode  /  :sc      — parcourir sccode.org",
    "  :browse              — sons : samples / instruments / synths",
    "  :doc <nom>           — docstring + exemples",
    "  :scale list          — gammes enregistrées (pat |> scale(s))",
    "  :starter <genre>     — charge un starter pack",
    "  :mute dN / :unmute dN / :solo dN",
    "  :scope amp|wave|spectrum|off",
    "  :theme <nom>         — change de thème",
    "  :reload-config       — recharge ./ressac.toml",
    "  :hush / :panic       — tout arrêter (doux / brutal)",
    "  :safety on|off       — limiteur + DC block + HPF 10 Hz",
    "  :wiki / :help        — wiki intégré / cette aide",
    "  :dsl                 — guide du DSL de synthèse",
    "  :snip / :snippets    — snippets (Enter insère)",
    "  :pause               — fige le rendu pour copier du texte",
    "  :keydebug            — journalise chaque touche",
    "  :copylogs            — copie le journal dans le presse-papier",
    "",
    "▓ SESSIONS & FICHIERS",
    "  :save <nom>          — sauve le buffer patterns dans sessions/<nom>.txt",
    "  :load <nom>          — charge une session dans la pane patterns",
    "  :sessions            — liste les sessions (Tab sur :load complète)",
    "  Après :load, presse E pour tout évaluer.",
    "",
    "▓ TAP / PIANO",
    "  :tap [sample]        — tape un rythme, Enter le pose en @dN p\"…\"",
    "                         (détecte la période, règle cps, évalue)",
    "  :tap-strict [sample] — idem sans détection de boucle",
    "  :bpm / :tap-tempo    — tape 2+ temps pour régler cps",
    "  :piano [synth]       — le clavier joue des demi-tons",
    "  :piano-rec [synth]   — idem + enregistre dans une ligne @dN",
    "",
    "▓ PANE SYNTH",
    "  :w / :w <nom>        — sauver (sauver-sous ouvre une nouvelle pane)",
    "  :close / :back       — fermer la pane / toutes les panes synth",
    "  :tabs                — lister les panes synth ouvertes",
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
    w = String(word)
    # 1. Plugin / user-contributed docs (last-wins highest priority).
    e = lookup_doc(w)
    e !== nothing && return e.short
    # 2. DSL-specific entries — for things we built ourselves with
    #    no SC counterpart (chan, amp, the @synth macro, etc.).
    haskey(_DSL_DOCS, w) && return _DSL_DOCS[w]
    # 3. DSL function → SC UGen mapping. Most DSL helpers are thin
    #    wrappers around a single UGen; this hop reuses the SC doc
    #    automatically without hand-writing a description per wrapper.
    if haskey(_DSL_TO_SCUGEN, w)
        sc_key = _DSL_TO_SCUGEN[w]
        doc = get(_SC_UGEN_DOCS, sc_key, nothing)
        doc !== nothing && return doc
    end
    # 4. Direct SC UGen lookup (when the user writes SinOsc / LPF
    #    verbatim in a Sig string).
    doc = get(_SC_UGEN_DOCS, w, nothing)
    doc !== nothing && return doc
    if occursin('.', w)
        head, _ = split(w, '.'; limit=2)
        doc = get(_SC_UGEN_DOCS, String(head), nothing)
        doc !== nothing && return doc
        e_head = lookup_doc(String(head))
        e_head !== nothing && return e_head.short
        _, tail = split(w, '.'; limit=2)
        doc = get(_SC_UGEN_DOCS, String(tail), nothing)
        doc !== nothing && return doc
    end
    return nothing
end

# ── DSL → SC UGen mapping ───────────────────────────────────────────
# Snake-case DSL wrapper name → the primary SC UGen it wraps. For
# functions that compose multiple UGens (the env_* family wrapping
# both `EnvGen` and `Env.<shape>`), prefer the MORE SPECIFIC name
# (Env.linen rather than EnvGen) so the user gets the per-shape doc.
const _DSL_TO_SCUGEN = Dict{String,String}(
    # Oscillators
    "sin_osc"     => "SinOsc",
    "saw"         => "Saw",
    "pulse"       => "Pulse",
    "tri"         => "LFTri",
    "square"      => "LFPulse",
    "var_saw"     => "VarSaw",
    "blip"        => "Blip",
    "formant"     => "Formant",
    "klang"       => "Klang",
    "impulse_ar"  => "Impulse",
    "impulse_kr"  => "Impulse",
    # Noise
    "white"       => "WhiteNoise",
    "pink"        => "PinkNoise",
    "brown"       => "BrownNoise",
    "gray"        => "GrayNoise",
    "clip_noise"  => "ClipNoise",
    "crackle"     => "Crackle",
    "dust"        => "Dust",
    "dust2"       => "Dust2",
    "lf_noise0"   => "LFNoise0",
    "lf_noise1"   => "LFNoise1",
    "lf_noise2"   => "LFNoise2",
    # Chaos
    "lorenz"      => "LorenzL",
    "henon"       => "HenonC",
    "logistic"    => "LogisticN",
    "standard_map"=> "StandardN",
    "latoo"       => "LatoocarfianC",
    "lincong"     => "LinCongC",
    "quad"        => "QuadC",
    "fbsine"      => "FBSineC",
    "gbman"       => "GbmanC",
    "cusp"        => "CuspC",
    # LFOs (control-rate)
    "lfo"         => "SinOsc",
    "lfo_saw"     => "LFSaw",
    "lfo_tri"     => "LFTri",
    "lfo_pulse"   => "LFPulse",
    "lf_cub"      => "LFCub",
    "lf_par"      => "LFPar",
    # Ramps / lags
    "line"        => "Line",
    "x_line"      => "XLine",
    "ramp_kr"     => "Ramp",
    "lag_kr"      => "Lag",
    "lag2_kr"     => "Lag2",
    "lag3_kr"     => "Lag3",
    # Filters
    "low_pass"    => "LPF",
    "high_pass"   => "HPF",
    "band_pass"   => "BPF",
    "band_reject" => "BRF",
    "rlpf"        => "RLPF",
    "rhpf"        => "RHPF",
    "moog_ff"     => "MoogFF",
    "leak_dc"     => "LeakDC",
    "median"      => "Median",
    "slope_kr"    => "Slope",
    # Biquad
    "b_low_pass"  => "BLowPass",
    "b_high_pass" => "BHiPass",
    "b_peak_eq"   => "BPeakEQ",
    "b_low_shelf" => "BLowShelf",
    "b_high_shelf"=> "BHiShelf",
    # Delays / combs / allpass
    "delay_n"     => "DelayN",
    "delay_l"     => "DelayL",
    "delay_c"     => "DelayC",
    "comb_n"      => "CombN",
    "comb_l"      => "CombL",
    "comb_c"      => "CombC",
    "allpass_n"   => "AllpassN",
    "allpass_l"   => "AllpassL",
    "allpass_c"   => "AllpassC",
    # Reverb / decay
    "free_verb"   => "FreeVerb",
    "g_verb"      => "GVerb",
    "decay"       => "Decay",
    "decay2"      => "Decay2",
    # FX
    "chorus"      => "DelayC",      # implemented as modulated delay
    "flanger"     => "DelayC",
    "phaser"      => "Allpass",
    # Granular
    "grain_buf"   => "GrainBuf",
    "warp1"       => "Warp1",
    # Spatial
    "stereo_pan"  => "Pan2",
    "stereo_pan_lin" => "LinPan2",
    "stereo_balance" => "Balance2",
    "stereo_rotate"  => "Rotate2",
    "splay"       => "Splay",
    "mix_sigs"    => "Mix",
    # Distortion / shaping
    "tanh_drive"  => "Tanh",
    "soft_clip"   => "SoftClipper",
    "cubic"       => "CubicDistort",
    "clip"        => "Clip",
    "fold"        => "Fold",
    "wrap"        => "Wrap",
    "decimator"   => "Decimator",
    # Envelopes — point at Env.<shape> for the specific doc.
    "env_perc"    => "Env.perc",
    "env_linen"   => "Env.linen",
    "env_adsr"    => "Env.adsr",
    "env_asr"     => "Env.asr",
    "env_cutoff"  => "Env.cutoff",
    "env_sine"    => "Env.sine",
    "env_dadsr"   => "Env.dadsr",
    "env_pairs"   => "Env.pairs",
    # Triggers
    "trig_kr"     => "Trig",
    "t_delay"     => "TDelay",
    "pitch_shift" => "PitchShift",
    "freq_shift"  => "FreqShift",
    "vibrato_sig" => "Vibrato",
    # Rate converters
    "to_kr"       => "A2K",
    "to_ar"       => "K2A",
    # Buffer reads
    "play_buf"    => "PlayBuf",
    "buf_rd"      => "BufRd",
)

# ── DSL-specific docs ───────────────────────────────────────────────
# For DSL constructs that have no direct SC counterpart — wrappers
# that bake multiple UGens, value combinators, the @synth macro, etc.
const _DSL_DOCS = Dict{String,String}(
    "@synth" => "@synth :nom (params...) begin <pipeline Sig> end — déclare un SynthDef SC compilé depuis un pipeline DSL.",
    "Sig"    => "Sig(\"<code SC brut>\") — échappatoire : enveloppe du SC arbitraire dans un Sig pour continuer en DSL.",
    "chan"   => "chan(elems...) — émet un tableau multicanal SC `[a, b, …]` comme un seul Sig. Compose avec `.+` pour l'arithmétique par canal.",
    "amp"    => "amp(x) — multiplication d'amplitude en pipe : `sig |> amp(0.5)` = `sig * 0.5`.",
    "offset" => "offset(x) — décalage additif en pipe : `sig |> offset(0.1)`.",
    "abs_sig"=> "abs_sig(s) — valeur absolue d'un Sig (`s.abs` en SC).",
    "sqrt_sig"=> "sqrt_sig(s) — racine carrée (`s.sqrt` en SC).",
    "pow_sig" => "pow_sig(s, n) — élève un Sig à une puissance (`s.pow(n)` en SC).",
    "sc_arg"  => "sc_arg(x) — rend une valeur Julia (Sig / Symbol / Real / Array) en source SC. Utilisé par tous les wrappers DSL.",
    "ugen"    => "ugen(name, args...; rate=\"ar\") — constructeur brut pour un UGen sans helper DSL.",
    "register_synth!" => "register_synth!(entry::SynthEntry) — installe un synth dans le registre global (appelé par @synth).",
    "env"     => "env(levels, times; curve=:lin) — construit une spec Env SC brute comme Sig. À donner à env_gen pour un contrôle total.",
    "env_gen" => "env_gen(envspec; gate=1, level_scale=1, level_bias=0, time_scale=1, done_action=2) — wrapper EnvGen.kr brut, expose chaque argument. Pipe : `sig |> env_gen(e)`.",
)

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
