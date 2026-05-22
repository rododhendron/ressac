// Minimal SynthDef for testing.
SynthDef(\bassline, { |out=0, freq=110, amp=0.5|
    Out.ar(out, SinOsc.ar(freq) * amp);
}).add;
