// rezzbass.scd  —  Wobble bass à la Rezz
// LFO on the filter cutoff at a sync-friendly rate produces the
// wobble. The rate param is in Hz — try 4 for 8th notes at 120bpm.
SynthDef(\darkscille, { |out, pan = 0, freq = 43, sustain = 5.0, gain = 0.3,
                      rate = 0.9, depth = 2000, base = 680, q = 0.16, drive = 0.8|
    var osc, lfo, cutoff, filt, amp, sig;
    osc = Saw.ar(freq) + (Saw.ar(freq * 0.3) * -0.6);
    lfo = SinOsc.kr(rate).range(base, base + depth);
    filt = RLPF.ar(osc, lfo, q);
    filt = ((filt * (1 + drive))).tanh;
    amp = EnvGen.kr(Env.linen(0.005, sustain - 0.02, 0.015), doneAction: 2);
    sig = filt * amp * gain;
    OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
}).add;
