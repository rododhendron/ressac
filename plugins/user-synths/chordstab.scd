// chordstab.scd  —  Lofi chord stab (root + min3 + 5)
// Plays a small minor triad at `freq`. Use `:degree` patterning
// to move the root around.
SynthDef(\chordstab, { |out, pan = 0, freq = 220, sustain = 0.4, gain = 0.45|
    var stack, filt, amp, sig;
    stack = Mix.ar([Saw.ar(freq), Saw.ar(freq * 1.189), Saw.ar(freq * 1.498)]) * 0.25;
    filt = LPF.ar(stack, 2200);
    amp = EnvGen.kr(Env.perc(0.005, sustain, 1, -3), doneAction: 2);
    sig = filt * amp * gain;
    OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
}).add;
