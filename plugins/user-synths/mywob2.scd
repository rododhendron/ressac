// mywob.scd  —  press T to test, :reload to push, :save-synth to persist.
//
// PARAMS = OSC keys drivable from Ressac: `p"mywob" |> set(:rate, 8)` etc.
// DEFAULTS below ARE used by T (the test trigger sends only `s` + `cut`,
// so changing `rate = 4` to `rate = 1` is audible). When you use the
// synth from a pattern (`@d1 p"mywob"`), SuperDirt overrides `freq`,
// `gain`, `sustain` from cycle + n — patterns shape the music, defaults
// shape the timbre.

SynthDef(\\mywob2, { |out, pan = 0, freq = 33, sustain = 0.15, gain = 0.5, accelerate = -0.1,
                    attack = 0.01, release = 0.12,
                    rate = 6, depth = 2000, centre = 800, q = 0.3, shape = 0.4|
    var lfo, osc, filt, env, sig;
    lfo  = SinOsc.kr(rate).range(centre - depth, centre + depth).max(60);
    osc  = Saw.ar(freq * Line.kr(1, 1 + accelerate, sustain));
    filt = RLPF.ar(osc, lfo, q);
    filt = (filt * (1 + (shape * 5))).tanh;
    env  = EnvGen.kr(Env.linen(attack, sustain, release), doneAction: 2);
    sig  = filt * env * gain;
    OffsetOut.ar(out, DirtPan.ar(sig, ~dirt.numChannels, pan));
}).add;
