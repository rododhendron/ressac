var lfo = SinOsc.kr(rate).range(low, high);
filt = RLPF.ar(osc, lfo, q);
