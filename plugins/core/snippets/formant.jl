var vow = SinOsc.kr(vowel_rate).range(400, 1800);
filt = BPF.ar(osc, vow, 0.25);
