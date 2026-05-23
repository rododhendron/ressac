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
    var burstEnv, excite, loop, amp, sig;

    // 5 ms of white noise → the initial "pluck" excitation.
    // EnvGen with Env.perc gives an instant attack + tiny decay.
    burstEnv = EnvGen.kr(Env.perc(0, burst));
    excite   = WhiteNoise.ar * burstEnv;

    // CombL = delay line with linear interpolation + feedback.
    // delaytime = 1/freq → loop period matches the desired pitch.
    // decay = sustain → how long until amplitude drops 60 dB.
    loop = CombL.ar(excite, 0.05, 1 / freq, sustain);

    // `damp` shapes how dark the sustained tone is (more damp =
    // softer, less damp = brighter & more brittle).
    loop = LPF.ar(loop, freq * (10 - (damp * 8)));

    // Amplitude envelope. doneAction:2 frees the synth when the
    // env reaches the end so it doesn't linger on the server.
    amp = EnvGen.kr(Env.linen(0.01, sustain, 0.1), doneAction: 2);

    sig = loop * amp * gain;
    OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
}).add;
