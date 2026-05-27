var ch_l = DelayN.ar(sig, 0.05, 0.011);
var ch_r = DelayN.ar(sig, 0.05, 0.017);
sig = (ch_l + ch_r) * 0.5;
