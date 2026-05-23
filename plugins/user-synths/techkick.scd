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
    var pitch, body, clk, amp, sig;

    // Pitch envelope: exponential drop from start_freq to freq.
    // Exponential because hertz on a log scale = musical pitch.
    pitch = EnvGen.kr(Env([start_freq, freq, freq],
                          [drop, sustain - drop], \exp));

    // Body: a sine at the moving pitch.
    body = SinOsc.ar(pitch);

    // Click transient. Short noise burst, low-passed so it's
    // a thump rather than a hiss. Amplitude drops in 5 ms.
    clk = (LPF.ar(WhiteNoise.ar, 4000)) *
          EnvGen.kr(Env.perc(0, 0.005)) * click;

    // Amplitude envelope. Sharp attack, exponential decay over
    // `sustain` for the tail.
    amp = EnvGen.kr(Env.perc(0.001, sustain, 1, -8),
                    doneAction: 2);

    // Soft saturation thickens the body without making it
    // distorted. tanh is the canonical "warm clipper" UGen.
    sig = ((body + clk) * amp * gain).tanh;
    OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
}).add;
