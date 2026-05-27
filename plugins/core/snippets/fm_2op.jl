var mod = SinOsc.ar(freq * mratio) *
          EnvGen.kr(Env([mindex, 0.3], [decay], \exp)) * freq;
sig = SinOsc.ar(freq + mod);
