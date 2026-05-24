// aurora.scd  —  Sweeping pad
SynthDef(\aurora, { |out, pan = 0, freq = 220, sustain = 4.0, gain = 0.4,
                    sweep = 3.0|
    var saws, env_sweep, filt, amp, sig;
    saws = Mix.ar(Array.fill(5, { |i|
        Saw.ar(freq * (1 + ((i - 2) * 0.008)))
    })) * 0.18;
    env_sweep = EnvGen.kr(Env([400, 4000, 400], [sweep * 0.5, sweep * 0.5], \sin));
    filt = RLPF.ar(saws, env_sweep, 0.4);
    amp = EnvGen.kr(Env([0, 1, 1, 0], [1.0, sustain - 2.0, 1.0], \sin),
                    doneAction: 2);
    sig = filt * amp * gain;
    OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
}).add;
