SynthDef(\myname, { |out, pan = 0, freq = 220, sustain = 0.5, gain = 0.5|
    var osc, amp, sig;
    osc = SinOsc.ar(freq);
    amp = EnvGen.kr(Env.linen(0.01, sustain, 0.1), doneAction: 2);
    sig = osc * amp * gain;
    OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
}).add;
