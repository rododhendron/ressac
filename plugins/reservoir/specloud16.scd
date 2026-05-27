// specloud16 — 16-partial additive voice used by reservoir Route II
// (spectral cloud / additive resynthesis).
//
// Each frame fired from Ressac carries fresh `freq_i` + `amp_i` for
// i ∈ 1..16, so a sequence of overlapping frames produces a slowly-
// evolving harmonic cloud whose spectrum tracks the reservoir state.
//
// The triangular envelope is keyed to `sustain`; firing frames at
// `frames_per_cycle` with `overlap = 2.0` gives ~50% cross-fade
// between frames for smooth transitions.

SynthDef(\specloud16, { |out, pan = 0, sustain = 0.125, gain = 0.3,
                         freq_1 = 110, freq_2 = 138.59, freq_3 = 174.61, freq_4 = 220,
                         freq_5 = 277.18, freq_6 = 349.23, freq_7 = 440, freq_8 = 554.37,
                         freq_9 = 698.46, freq_10 = 880, freq_11 = 1108.73, freq_12 = 1396.91,
                         freq_13 = 1760, freq_14 = 2217.46, freq_15 = 2793.83, freq_16 = 3520,
                         amp_1 = 0, amp_2 = 0, amp_3 = 0, amp_4 = 0,
                         amp_5 = 0, amp_6 = 0, amp_7 = 0, amp_8 = 0,
                         amp_9 = 0, amp_10 = 0, amp_11 = 0, amp_12 = 0,
                         amp_13 = 0, amp_14 = 0, amp_15 = 0, amp_16 = 0|
    var freqs, amps, sines, env, sig;
    freqs = [freq_1, freq_2, freq_3, freq_4, freq_5, freq_6, freq_7, freq_8,
             freq_9, freq_10, freq_11, freq_12, freq_13, freq_14, freq_15, freq_16];
    amps  = [amp_1, amp_2, amp_3, amp_4, amp_5, amp_6, amp_7, amp_8,
             amp_9, amp_10, amp_11, amp_12, amp_13, amp_14, amp_15, amp_16];
    sines = SinOsc.ar(freqs) * amps;
    // Triangle window — 25% attack, 50% hold, 25% release — gives the
    // crossfade between successive frames an audible-but-not-clicky shape.
    env = EnvGen.kr(Env.new([0, 1, 1, 0], [0.25, 0.5, 0.25] * sustain),
                    doneAction: 2);
    sig = Mix(sines) * env * gain;
    OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
}).add;
