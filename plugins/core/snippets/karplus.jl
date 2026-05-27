var exc = WhiteNoise.ar * EnvGen.kr(Env.perc(0, 0.005));
var loop = CombL.ar(exc, 0.05, 1 / freq, sustain);
loop = LPF.ar(loop, freq * 4);
