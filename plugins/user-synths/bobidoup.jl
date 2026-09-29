@synth :bobidoup (freq=432.3783290563658, sustain=0.6716906664148345) feedback() do fb
    n1 = ugen(:AllpassC, ugen(:DC, :freq), 0.3, 0.1, 1.0)
    n2 = ugen(:SinOsc, 0.05; rate = :kr)
    n3 = n1 + n2
    n4 = ugen(:LFPulse, 4.0, 0.0, 0.5; rate = :kr)
    n5 = ugen(:SinOsc, n3, n4; rate = :kr)
    n6 = ugen(:SinOsc, fb; rate = :kr)
    n7 = ugen(:RLPF, ugen(:K2A, n5), 400.0, n6)
    ugen(:Limiter, ugen(:LeakDC, ugen(:Sanitize, n7)), 0.95)
end

# ressac-genome: {"controls":{"freq":432.3783290563658,"gain":0.5,"release":0.0702560918771189,"sustain":0.6716906664148345},"next_id":10,"nodes":[{"args":[{"name":"freq","t":"ctrl"},{"t":"const","v":0.3},{"t":"const","v":0.1},{"t":"const","v":1.0}],"id":5,"rate":"ar","ugen":"AllpassC"},{"args":[{"t":"const","v":0.05}],"id":6,"rate":"kr","ugen":"SinOscKR"},{"args":[{"id":5,"t":"node"},{"id":6,"t":"node"}],"id":7,"rate":"ar","ugen":"Mix"},{"args":[{"id":1,"t":"node"},{"t":"const","v":400.0},{"id":3,"t":"node"}],"id":2,"rate":"ar","ugen":"RLPF"},{"args":[{"t":"const","v":4.0},{"t":"const","v":0.0},{"t":"const","v":0.5}],"id":9,"rate":"kr","ugen":"LFPulseKR"},{"args":[],"id":8,"rate":"ar","ugen":"FbIn"},{"args":[{"id":8,"t":"node"}],"id":3,"rate":"kr","ugen":"SinOscKR"},{"args":[{"id":7,"t":"node"},{"id":9,"t":"node"}],"id":1,"rate":"kr","ugen":"SinOsc"}],"output":2}
