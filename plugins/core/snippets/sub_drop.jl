var pitch = EnvGen.kr(Env([start_freq, freq], [drop], \exp));
sig = SinOsc.ar(pitch);
