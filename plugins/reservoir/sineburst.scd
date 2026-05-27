// sineburst — percussive sine voice used by reservoir Route I.
//
// Each spike from the reservoir fires one of these at the frequency
// assigned by the chosen layout. SuperDirt overrides freq / gain /
// sustain from the pattern event; defaults are useful for the test
// trigger (T) when iterating live.

SynthDef(\sineburst, { |out, pan = 0, freq = 440, sustain = 0.05, gain = 0.5,
                        attack = 0.003, release = 0.04|
    var env, sig;
    env  = EnvGen.kr(Env.perc(attack, max(sustain - attack, release)),
                     doneAction: 2);
    sig  = SinOsc.ar(freq) * env * gain;
    OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
}).add;
