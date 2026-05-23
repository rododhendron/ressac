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
    var saws, lfo, filt, ch_l, ch_r, stereo, amp, sig;

    // 5 detuned saws. Each one is offset by a small multiple
    // of `detune`. Spread across the centre frequency.
    saws = Mix.ar(Array.fill(5, { |i|
        var d = (i - 2) * detune;
        Saw.ar(freq * (1 + d)) * 0.2
    }));

    // LFO modulates cutoff slightly so the timbre breathes.
    lfo = SinOsc.kr(0.1).range(0.8, 1.2);

    // Filter. Low cutoff + moderate Q = warm and dark.
    filt = RLPF.ar(saws, cutoff * lfo, q);

    // Stereo widening via two short delays (left and right).
    ch_l = DelayN.ar(filt, 0.05, 0.011);
    ch_r = DelayN.ar(filt, 0.05, 0.017);
    stereo = [ch_l, ch_r];

    // Slow attack envelope. doneAction:2 frees after release.
    amp = EnvGen.kr(Env([0, 1, 1, 0],
                        [attack, sustain - attack, release],
                        \sin),
                    doneAction: 2);

    sig = stereo * amp * gain;
    OffsetOut.ar(out, DirtPan.ar(sig.sum, ~dirt.numChannels, pan));
}).add;
