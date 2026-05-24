// silkstring.scd  —  Bowed-saw string
SynthDef(\silkstring, { |out, pan = 0, freq = 440, sustain = 1.2, gain = 0.4,
                        vibrato = 5, vib_depth = 3|
    var lfo, osc, filt, amp, sig;
    lfo = SinOsc.kr(vibrato) * vib_depth;
    osc = Saw.ar(freq + lfo) + Saw.ar(freq + lfo + 0.7);
    filt = RLPF.ar(osc * 0.3, 3000, 0.5);
    amp = EnvGen.kr(Env([0, 1, 1, 0], [0.15, sustain * 0.6, sustain * 0.3], \sin),
                    doneAction: 2);
    sig = filt * amp * gain;
    OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
}).add;
