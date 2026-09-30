@synth :candidat__1 (freq=408.1107981565365, sustain=3.0194406664148348, modulation=0.7 , vromb=30, pulse_width=0.9) feedback() do fb
    n1 = ugen(:AllpassC, 400.0, 5.0350000000000001, 0.00507499999999998, 0.9400000000000013, 3, 6)
    n5 = ugen(:SinOsc, n1; rate = :kr)
    n6 = ugen(:SinOsc, [fb, fb + 1]; rate = :kr)
    n7 = ugen(:RLPF, ugen(:K2A, n5), 200.0000000000007, n6)
    n8 = 0.007778780781446 + n7
    n9 = ugen(:LFPulse, :vromb, 0.175000000000002, :pulse_width; rate = :kr)
    n10 = ugen(:SinOsc, n8, n9; rate = :kr)
    n11 = ugen(:SinOsc, fb; rate = :kr)
    n12 = ugen(:RLPF, ugen(:K2A, n10), :freq, n11)
    modu = ugen(:SinOsc, :modulation, 0.3, 0.9, 0.0; rate=:kr)
    out = modu * n12
    ugen(:Limiter, ugen(:LeakDC, ugen(:Sanitize, out)), 0.95)
end