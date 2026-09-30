@synth :pebblesaw_clean (freq=584.7492564873866, sustain=1.1806367381129679) feedback() do fb
    n1 = ugen(:MoogFF, ugen(:DC, :freq), 1000.0, 2.0)
    n2 = ugen(:Saw, n1)
    n3 = ugen(:RLPF, n2, 400.0, 0.3)
    n4 = ugen(:Ringz, ugen(:DC, :freq), 2000.0, 0.5)
    n5 = ugen(:Saw, n4)
    n6 = n3 + n5
    n7 = ugen(:Ringz, n6, 2000.0, 0.5)
    n8 = ugen(:LFPulse, n7, 0.0, 0.5; rate = :kr)
    n9 = ugen(:MoogFF, ugen(:DC, :freq), n8, 2.0)
    n10 = ugen(:Saw, n9)
    n11 = ugen(:RLPF, n10, 400.0, 0.3)
    n12 = ugen(:LFPulse, 4.0, 0.0, 0.5; rate = :kr)
    n13 = ugen(:MoogFF, ugen(:DC, :freq), n12, 2.0)
    n14 = ugen(:Saw, n13)
    n15 = ugen(:RLPF, n14, 400.0, 0.3)
    n16 = n11 + n15
    n17 = ugen(:Saw, fb)
    n18 = n16 + n17
    n19 = ugen(:RLPF, n18, 400.0, 0.05)
    ugen(:Limiter, ugen(:LeakDC, ugen(:Sanitize, n19)), 0.95)
end
