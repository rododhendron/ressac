@synth :deadscreen (freq=101.63148171537014, sustain=0.5985092598772751) begin
    n1 = ugen(:SinOsc, :freq, 0.0; rate = :kr)
    n2 = ugen(:SinOsc, n1, 0.0; rate = :kr)
    n3 = ugen(:SinOsc, :freq, 0.0; rate = :kr)
    n4 = ugen(:LFNoise1, n3; rate = :kr)
    n5 = ugen(:AllpassC, ugen(:DC, :freq), n4, 0.1, 1.0)
    n6 = ugen(:SinOsc, n5, 0.0; rate = :kr)
    n7 = ugen(:Ringz, ugen(:DC, 2000.0), n6, 0.5)
    n8 = ugen(:Ringz, ugen(:K2A, n2), n7, 0.5)
    n9 = ugen(:SinOsc, :freq, 0.0; rate = :kr)
    n10 = ugen(:LFPulse, n9, 0.0, 0.5; rate = :kr)
    n11 = ugen(:RLPF, n8, 400.0, n10)
    ugen(:Limiter, ugen(:LeakDC, ugen(:Sanitize, n11)), 0.95)
end

# ressac-genome: {"controls":{"freq":101.63148171537014,"gain":0.5,"release":0.13157183169965253,"sustain":0.5985092598772751},"next_id":13,"nodes":[{"args":[{"name":"freq","t":"ctrl"},{"t":"const","v":0.0}],"id":5,"rate":"kr","ugen":"SinOsc"},{"args":[{"id":9,"t":"node"},{"t":"const","v":0.0}],"id":8,"rate":"kr","ugen":"SinOsc"},{"args":[{"id":7,"t":"node"},{"t":"const","v":0.0}],"id":1,"rate":"kr","ugen":"SinOsc"},{"args":[{"t":"const","v":2000.0},{"id":8,"t":"node"},{"t":"const","v":0.5}],"id":6,"rate":"ar","ugen":"Ringz"},{"args":[{"name":"freq","t":"ctrl"},{"t":"const","v":0.0}],"id":11,"rate":"kr","ugen":"SinOsc"},{"args":[{"name":"freq","t":"ctrl"},{"id":10,"t":"node"},{"t":"const","v":0.1},{"t":"const","v":1.0}],"id":9,"rate":"ar","ugen":"AllpassC"},{"args":[{"id":5,"t":"node"},{"t":"const","v":0.0},{"t":"const","v":0.5}],"id":3,"rate":"kr","ugen":"LFPulseKR"},{"args":[{"name":"freq","t":"ctrl"},{"t":"const","v":0.0}],"id":7,"rate":"kr","ugen":"SinOsc"},{"args":[{"id":1,"t":"node"},{"id":6,"t":"node"},{"t":"const","v":0.5}],"id":4,"rate":"ar","ugen":"Ringz"},{"args":[{"id":4,"t":"node"},{"t":"const","v":400.0},{"id":3,"t":"node"}],"id":2,"rate":"ar","ugen":"RLPF"},{"args":[{"id":11,"t":"node"}],"id":10,"rate":"kr","ugen":"LFNoise1"}],"output":2}
