// chordstab.scd  —  Lofi chord stab (root + min3 + 5)
// Plays a small minor triad at `freq`. Use `:degree` patterning
// to move the root around.
SynthDef(\mypattern, { |out, pan = 0, freq = 220, sustain = 0.5, gain = 0.55|
    var stack, filt, amp, sig;
    stack = Mix.ar([Saw.ar(freq), Saw.ar(freq * 0.989), Saw.ar(freq * 1.598)]) * 0.25;
    filt = LPF.ar(stack, 2250);
    amp = EnvGen.kr(Env.perc(0.015, sustain, 1, 2, -5, -2), doneAction: 2);
    sig = filt * amp * gain;
    OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
}).add;
