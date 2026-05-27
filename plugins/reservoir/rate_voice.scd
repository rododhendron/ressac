// rate_voice SynthDefs — continuous oscillator voices whose freq is
// set from the reservoir's measured firing rate. A neuron firing at
// 200 spikes/sec maps to a 200 Hz oscillator → the listener literally
// hears the spike rate as pitch.
//
// Four flavours, all sharing the same arg surface (freq, sustain,
// gain, pan) so they're interchangeable in the route:
//   rate_impulse — raw Impulse.ar click train (very buzzy)
//   rate_saw     — Saw.ar (harmonic-rich sawtooth)
//   rate_sin     — SinOsc.ar (pure tone)
//   rate_pulse   — Pulse.ar (square-ish, width=0.4)
//
// Each event from the route fires one short voice with sustain = the
// frame duration × overlap, so successive frames cross-fade and the
// pitch evolution feels continuous.

SynthDef(\rate_impulse, { |out, pan = 0, freq = 200, sustain = 0.25, gain = 0.3,
                           attack = 0.005, release = 0.05|
    var env, sig;
    env = EnvGen.kr(Env.linen(attack, max(sustain - attack - release, 0.001), release),
                    doneAction: 2);
    sig = Impulse.ar(freq) * env * gain;
    OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
}).add;

SynthDef(\rate_saw, { |out, pan = 0, freq = 200, sustain = 0.25, gain = 0.3,
                       attack = 0.005, release = 0.05|
    var env, sig;
    env = EnvGen.kr(Env.linen(attack, max(sustain - attack - release, 0.001), release),
                    doneAction: 2);
    sig = Saw.ar(freq) * env * gain;
    OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
}).add;

SynthDef(\rate_sin, { |out, pan = 0, freq = 200, sustain = 0.25, gain = 0.3,
                       attack = 0.005, release = 0.05|
    var env, sig;
    env = EnvGen.kr(Env.linen(attack, max(sustain - attack - release, 0.001), release),
                    doneAction: 2);
    sig = SinOsc.ar(freq) * env * gain;
    OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
}).add;

SynthDef(\rate_pulse, { |out, pan = 0, freq = 200, sustain = 0.25, gain = 0.3,
                         attack = 0.005, release = 0.05, width = 0.4|
    var env, sig;
    env = EnvGen.kr(Env.linen(attack, max(sustain - attack - release, 0.001), release),
                    doneAction: 2);
    sig = Pulse.ar(freq, width) * env * gain;
    OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
}).add;
