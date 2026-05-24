// ─ DSL recipe (Julia / Ressac.SynthDSL) ────────────────
//   saw(:freq) |> decimator(11025, 4) |> low_pass(1200)
// ────────────────────────────────────────────────────────

SynthDef(\dustbass, { |out, pan = 0, freq = 70, sustain = 0.4, gain = 0.5|
    OffsetOut.ar(out, DirtPan.ar(((LPF.ar(Decimator.ar(Saw.ar(freq), 11025, 4), 1200) * EnvGen.kr(Env.linen(0.01, sustain, 0.1), doneAction: 2)) * gain), ~dirt.numChannels, pan));
}).add;
