@synth :truc1 (freq=166.2119194416244, sustain=0.5097594408680095) begin
    n1 = ugen(:Saw, :freq)
    n2 = 4.0 |> clip2(1.0)
    n3 = ugen(:LFPulse, n2, 0.0, 0.32213696226169086; rate = :kr)
    n4 = 4.0 |> clip2(1.0)
    n5 = ugen(:LFPulse, n4, 0.0, 0.32213696226169086; rate = :kr)
    n6 = n3 + n5
    n7 = n1 + n6
    n8 = ugen(:Midicps, 4.0)
    n9 = ugen(:Cubed, n8)
    n10 = ugen(:LFPulse, n9, 0.0, 0.5; rate = :kr)
    n11 = ugen(:RLPF, n7, 400.0, n10)
    ugen(:Limiter, ugen(:LeakDC, ugen(:Sanitize, n11)), 0.95)
end

# ressac-genome: {"controls":{"freq":166.2119194416244,"gain":0.5,"release":0.0,"sustain":0.5097594408680095},"next_id":13,"nodes":[{"args":[{"id":1,"t":"node"},{"id":12,"t":"node"}],"id":5,"rate":"ar","ugen":"Mix"},{"args":[{"id":4,"t":"node"},{"id":10,"t":"node"}],"id":12,"rate":"ar","ugen":"Mix"},{"args":[{"t":"const","v":4.0}],"id":8,"rate":"ar","ugen":"Midicps"},{"args":[{"name":"freq","t":"ctrl"}],"id":1,"rate":"ar","ugen":"Saw"},{"args":[{"t":"const","v":4.0},{"t":"const","v":1.0}],"id":11,"rate":"ar","ugen":"Clip2"},{"args":[{"t":"const","v":4.0},{"t":"const","v":1.0}],"id":9,"rate":"ar","ugen":"Clip2"},{"args":[{"id":7,"t":"node"},{"t":"const","v":0.0},{"t":"const","v":0.5}],"id":3,"rate":"kr","ugen":"LFPulseKR"},{"args":[{"id":8,"t":"node"}],"id":7,"rate":"ar","ugen":"Cubed"},{"args":[{"id":9,"t":"node"},{"t":"const","v":0.0},{"t":"const","v":0.32213696226169086}],"id":4,"rate":"kr","ugen":"LFPulseKR"},{"args":[{"id":5,"t":"node"},{"t":"const","v":400.0},{"id":3,"t":"node"}],"id":2,"rate":"ar","ugen":"RLPF"},{"args":[{"id":11,"t":"node"},{"t":"const","v":0.0},{"t":"const","v":0.32213696226169086}],"id":10,"rate":"kr","ugen":"LFPulseKR"}],"output":2}
