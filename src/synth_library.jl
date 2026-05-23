# Curated SynthDef starters covering a range of styles. Each `source`
# field is the full .scd as the user would see it inside the synth tab,
# with comments explaining what each UGen does and why the
# combination produces the sound — so the library doubles as a tutorial.
#
# The browser modal (`:synthlib`) lists these by name + description;
# selecting one copies its source into plugins/user-synths/<name>.scd
# and opens it in a new synth tab so the user can iterate on a personal
# copy without touching the original template.

struct _SynthLibEntry
    name::String          # the SynthDef name (and filename stem)
    category::String      # "lead", "bass", "perc", "fx" — for grouping
    description::String   # one-line summary
    source::String        # the .scd body
end

const _SYNTH_LIBRARY = _SynthLibEntry[
    _SynthLibEntry(
        "plucky", "lead",
        "Karplus-Strong-ish plucked string. Noise → delay loop → filter.",
        raw"""
        // plucky.scd  —  Karplus-Strong plucked string
        //
        // Idea: feed a SHORT noise burst into a delay line whose length =
        // 1/freq. The output of the delay loops back into its input with
        // gentle low-pass filtering each pass. The noise quickly settles
        // into a periodic waveform at the delay's resonant frequency —
        // that's the "string". Filtering damps the high harmonics over
        // time → realistic pluck decay.

        SynthDef(\plucky, { |out, pan = 0, freq = 220, sustain = 0.8, gain = 0.5,
                            burst = 0.005, damp = 0.5|
            // 5 ms of white noise → the initial "pluck" excitation.
            // EnvGen with Env.perc gives an instant attack + tiny decay.
            var burstEnv = EnvGen.kr(Env.perc(0, burst));
            var excite   = WhiteNoise.ar * burstEnv;

            // CombL = delay line with linear interpolation + feedback.
            // delaytime = 1/freq → loop period matches the desired pitch.
            // decay = sustain → how long until amplitude drops 60 dB.
            // `damp` shapes how dark the sustained tone is (more damp =
            // softer, less damp = brighter & more brittle).
            var loop = CombL.ar(excite, 0.05, 1 / freq, sustain);
            loop = LPF.ar(loop, freq * (10 - (damp * 8)));

            // Amplitude envelope. doneAction:2 frees the synth when the
            // env reaches the end so it doesn't linger on the server.
            var amp = EnvGen.kr(Env.linen(0.01, sustain, 0.1), doneAction: 2);

            var sig = loop * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """
    ),

    _SynthLibEntry(
        "acid303", "bass",
        "TB-303-style acid line. Saw → RLPF with envelope on cutoff.",
        raw"""
        // acid303.scd  —  Roland TB-303 inspired acid bass
        //
        // The classic acid sound has three ingredients:
        //  1. A SAW or SQUARE oscillator (lots of harmonics to filter).
        //  2. A resonant low-pass filter (RLPF) whose cutoff is swept
        //     down by a fast envelope on every note — that's the
        //     "wah" / "bloop".
        //  3. High resonance pushes the cutoff peak into self-oscillation,
        //     giving the squelchy character.

        SynthDef(\acid303, { |out, pan = 0, freq = 80, sustain = 0.3, gain = 0.5,
                             cutoff = 1500, resonance = 0.4, envmod = 4,
                             accent = 0.5, decay = 0.2|
            // Saw → bright source. Mix in a sub octave for thickness.
            var osc = Saw.ar(freq) + (SinOsc.ar(freq * 0.5) * 0.3);

            // Cutoff envelope: jumps from base * envmod down to base over
            // `decay` seconds. envmod=4 means the filter starts at 4× the
            // cutoff parameter, then sweeps down — that's the squelch.
            var cenv = EnvGen.kr(Env.perc(0.001, decay, 1, -4)) * envmod;
            var dyncut = cutoff * (1 + cenv);

            // RLPF with high `rq` close to 0 = high resonance. Be careful
            // with rq < 0.1 — can self-oscillate and clip. Multiply by
            // accent for that extra slide-on-high-notes bite.
            var filtered = RLPF.ar(osc, dyncut.clip(20, 18000),
                                   resonance.clip(0.05, 1.0));
            filtered = filtered * (1 + (accent * 0.8));

            // Amp envelope. Linen gives a snappy attack, sustain at
            // 1.0, then quick release.
            var amp = EnvGen.kr(Env.linen(0.005, sustain, 0.05),
                                doneAction: 2);

            var sig = (filtered * amp * gain).tanh;  // gentle limiter
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """
    ),

    _SynthLibEntry(
        "fmbell", "lead",
        "Two-operator FM bell. Modulator frequency controls timbre.",
        raw"""
        // fmbell.scd  —  Classic 2-op FM bell
        //
        // FM synthesis: ONE oscillator (the "modulator") shifts the
        // frequency of another (the "carrier") at audio rate. The ratio
        // between modulator and carrier frequencies determines which
        // partials are produced — integer ratios give harmonic tones,
        // non-integer ratios give inharmonic (bell, metallic) tones.
        //
        // The modulator's amplitude is the "modulation index". Higher
        // index = more harmonics. We sweep it down with an envelope so
        // the timbre evolves from bright/clangy to warm/sine over time.

        SynthDef(\fmbell, { |out, pan = 0, freq = 440, sustain = 1.2, gain = 0.4,
                            mratio = 1.41, mindex = 5, decay = 0.8|
            // Modulator: a sine at freq * mratio. mratio=1.41 (~sqrt 2)
            // gives the classic FM-bell inharmonicity.
            // Index envelope sweeps from `mindex` down to 0.5 across decay.
            var idxEnv = EnvGen.kr(Env([mindex, mindex * 0.3, 0.2],
                                       [0.05, decay], \exp));
            var mod = SinOsc.ar(freq * mratio) * idxEnv * freq;

            // Carrier: sine whose phase argument is offset by the
            // modulator. SinOsc's phase input handles audio-rate FM
            // directly. The carrier rings at `freq` but acquires
            // sidebands from the modulator.
            var car = SinOsc.ar(freq + mod);

            // Amp envelope. Bells have NO attack ramp — they ring instantly.
            // Slow release so the tail decays naturally.
            var amp = EnvGen.kr(Env.perc(0, sustain, 1, -4), doneAction: 2);

            var sig = car * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """
    ),

    _SynthLibEntry(
        "techkick", "perc",
        "Techno kick: sine with fast pitch drop + transient click.",
        raw"""
        // techkick.scd  —  Punchy techno kick drum
        //
        // A kick drum is two events in one:
        //  1. A short PITCH SWEEP from ~150 Hz down to ~40 Hz over a few
        //     dozen ms — the "thump".
        //  2. A click transient at the very start — the "beater".
        // Optionally a tiny bit of saturation on the body adds warmth and
        // makes the kick cut through a busy mix.

        SynthDef(\techkick, { |out, pan = 0, freq = 50, sustain = 0.4, gain = 0.8,
                              start_freq = 150, drop = 0.04, click = 0.6|
            // Pitch envelope: exponential drop from start_freq to freq.
            // Exponential because hertz on a log scale = musical pitch.
            var pitch = EnvGen.kr(Env([start_freq, freq, freq],
                                      [drop, sustain - drop], \exp));

            // Body: a sine at the moving pitch.
            var body = SinOsc.ar(pitch);

            // Click transient. Short noise burst, low-passed so it's
            // a thump rather than a hiss. Amplitude drops in 5 ms.
            var clk = (LPF.ar(WhiteNoise.ar, 4000)) *
                      EnvGen.kr(Env.perc(0, 0.005)) * click;

            // Amplitude envelope. Sharp attack, exponential decay over
            // `sustain` for the tail.
            var amp = EnvGen.kr(Env.perc(0.001, sustain, 1, -8),
                                doneAction: 2);

            // Soft saturation thickens the body without making it
            // distorted. tanh is the canonical "warm clipper" UGen.
            var sig = ((body + clk) * amp * gain).tanh;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """
    ),

    _SynthLibEntry(
        "softpad", "pad",
        "Detuned saw stack + slow attack + chorus. Ambient pad.",
        raw"""
        // softpad.scd  —  Lush ambient pad
        //
        // A pad sound is built from layers:
        //  1. Multiple SAW oscillators tuned slightly apart ("super-saw")
        //     so phasing between them creates a moving, lush texture.
        //  2. A LOW-PASS FILTER tames the harshness of the saws.
        //  3. CHORUS-like delays widen the stereo image.
        //  4. SLOW attack + slow release so notes blend into chords.

        SynthDef(\softpad, { |out, pan = 0, freq = 220, sustain = 2.5, gain = 0.35,
                             attack = 0.5, release = 1.5, detune = 0.01,
                             cutoff = 2500, q = 0.5|
            // 5 detuned saws. Each one is offset by a small multiple
            // of `detune`. spread across the centre frequency.
            var saws = Mix.ar(Array.fill(5, { |i|
                var d = (i - 2) * detune;
                Saw.ar(freq * (1 + d)) * 0.2
            }));

            // Filter. Low cutoff + moderate Q = warm and dark.
            // Modulate cutoff slightly with an LFO so the timbre breathes.
            var lfo = SinOsc.kr(0.1).range(0.8, 1.2);
            var filt = RLPF.ar(saws, cutoff * lfo, q);

            // Stereo widening via two short delays (left and right).
            var ch_l = DelayN.ar(filt, 0.05, 0.011);
            var ch_r = DelayN.ar(filt, 0.05, 0.017);
            var stereo = [ch_l, ch_r];

            // Slow attack envelope. doneAction:2 frees after release.
            var amp = EnvGen.kr(Env([0, 1, 1, 0],
                                    [attack, sustain - attack, release],
                                    \sin),
                                doneAction: 2);

            var sig = stereo * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig.sum, ~dirt.numChannels, pan));
        }).add;
        """
    ),

    _SynthLibEntry(
        "hihat", "perc",
        "Hi-hat: filtered noise with sharp envelope.",
        raw"""
        // hihat.scd  —  Closed hi-hat from filtered noise
        //
        // Most cymbal/hat sounds are easiest to fake as filtered noise:
        // their spectrum is so dense and inharmonic that white noise
        // through a well-tuned bandpass gives a convincing result. The
        // envelope is what makes it "closed" vs "open" — short = closed,
        // long = open.

        SynthDef(\hihat, { |out, pan = 0, sustain = 0.08, gain = 0.4,
                           cutoff = 8000, q = 0.3, drive = 0.0|
            // Noise source: pink is a touch warmer than white. Two HPFs
            // in series chop the lows hard so we get only the "tss".
            var src = PinkNoise.ar;
            src = HPF.ar(src, 2000);
            src = HPF.ar(src, cutoff * 0.3);

            // Bandpass colours the noise — emphasises a particular hat
            // brightness. Higher q = more pitched / metallic.
            var filt = BPF.ar(src, cutoff, q);

            // Optional saturation. drive=0 → clean; drive>0 → grittier.
            filt = filt + (filt.tanh * drive);

            // Very short envelope. Exp curve makes it feel snappy.
            var amp = EnvGen.kr(Env.perc(0.001, sustain, 1, -8),
                                doneAction: 2);

            var sig = filt * amp * gain;
            OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
        }).add;
        """
    ),
]
