@synth :somemetalressone (freq=480, sustain=2.9183663292027715) (auto_env=false,) begin
    n1 = ugen(:Saw, :freq + 3)
    n2 = ugen(:GbmanL, 2000.0)
    n3 = ugen(:FreeVerb, n1, n2, 1.1, 1.109421388571356)
    n4 = ugen(:Saw, n3)
    n5 = ugen(:Saw, n4)
    n6 = ugen(:Saw, n5)
    n7 = n6 + 5.1330354525817357
    n8 = ugen(:Saw, :freq + 1)
    n9 = ugen(:Saw, :freq - 1)
    n10 = ugen(:GbmanL, n9)
    n11 = ugen(:Formlet, n8, n10, 0.3, 1.109421388571356)
    n12 = ugen(:Saw, n11)
    n13 = n12 + 9.133035452581735
    n14 = ugen(:Saw, :freq + 2)
    n15 = ugen(:Dust, 1000.0)
    n16 = ugen(:FreeVerb, n14, n15, 0.1, 1.109421388571356)
    n17 = ugen(:Saw, n16)
    n18 = ugen(:Saw, :freq + 5)
    n19 = ugen(:LPF, n17, n18)
    n20 = ugen(:FreeVerb, n13, n19, 0.1, 1.109421388571356)
    n21 = ugen(:Formlet, n7, n20, 0.1, 1.109421388571356)
    ugen(:Limiter, ugen(:LeakDC, ugen(:Sanitize, n21)), 0.65)
end
