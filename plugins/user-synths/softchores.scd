// softpad.scd  —  Lush ambient pad
//
// A pad sound is built from layers:
//  1. Multiple SAW oscillators tuned slightly apart ("super-saw")
//     so phasing between them creates a moving, lush texture.
//  2. A LOW-PASS FILTER tames the harshness of the saws.
//  3. CHORUS-like delays widen the stereo image.
//  4. SLOW attack + slow release so notes blend into chords.

SynthDef(\softchores, { |out, pan = 0, freq = 340, sustain = 0.3, gain = 0.25,
                     attack = 0.3, release = 0.7, detune = 0.23,
                     cutoff = 2330, q = 0.07|
    var saws, lfo, filt, ch_l, ch_r, stereo, amp, sig;

    // 5 detuned saws. Each one is offset by a small multiple
    // of `detune`. Spread across the centre frequency.
    saws = Mix.ar(Array.fill(6, { |i|
        var d = (i - 4) * detune;
        Saw.ar(freq * (1 + d)) * 0.2
    }));

    // LFO modulates cutoff slightly so the timbre breathes.
    lfo = SinOsc.kr(0.2).range(0.3, 2.6);

    // Filter. Low cutoff + moderate Q = warm and dark.
    filt = RLPF.ar(saws, cutoff * lfo, q);

    // Stereo widening via two short delays (left and right).
    ch_l = DelayN.ar(filt, 0.05, 5.011);
    ch_r = DelayN.ar(filt, 0.05, 1.017);
    stereo = [ch_l, ch_r];

    // Slow attack envelope. doneAction:2 frees after release.
    amp = EnvGen.kr(Env([0, 1.2, 0.3, 0],
                        [attack, sustain - attack, release],
                        \sin),
                    doneAction: 2);

    sig = stereo * amp * gain;
    OffsetOut.ar(out, DirtPan.ar(sig.sum, ~dirt.numChannels, pan));
}).add;
