SynthDef(\myname, { |out, pan = 0, freq = 220, sustain = 0.5, gain = 0.5,
                    cutoff = 2000, resonance = 0.4|
    var osc, filt, amp, sig;
    osc = Saw.ar(freq);
    filt = RLPF.ar(osc, cutoff, resonance);
    amp = EnvGen.kr(Env.linen(0.005, sustain, 0.05), doneAction: 2);
    sig = filt * amp * gain;
    OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
}).add;
