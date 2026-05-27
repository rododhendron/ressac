var cenv = EnvGen.kr(Env.perc(0.001, 0.3, 1, -3)) * 4;
filt = RLPF.ar(osc, cutoff * (1 + cenv), q);
