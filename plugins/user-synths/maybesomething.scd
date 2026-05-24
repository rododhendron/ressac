// sketch_yy3.scd  —  press T to test, :reload to push, :save-synth to persist.
//
// PARAMS = OSC keys drivable from Ressac: `p"sketch_yy3" |> set(:rate, 8)` etc.
// DEFAULTS below ARE used by T (the test trigger sends only `s` + `cut`,
// so changing `rate = 4` to `rate = 1` is audible). When you use the
// synth from a pattern (`@d1 p"sketch_yy3"`), SuperDirt overrides `freq`,
// `gain`, `sustain` from cycle + n — patterns shape the music, defaults
// shape the timbre.


SynthDef(\maybesomething, { |out, pan = 0, freq = 195, sustain = 1.0, gain = 1.0|
    var osc, amp, sig;
    osc = SinOsc.ar([freq, freq + 1] + (32 + (33 * SinOsc.ar(35))));
    amp = EnvGen.kr(Env.linen(0.01, sustain, 0.1), doneAction: 2);
    sig = osc * amp * gain;
    OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
}).add;