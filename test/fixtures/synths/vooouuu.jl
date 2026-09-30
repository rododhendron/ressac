@synth :vooouuu (freq=129.44668993128087, sustain=0.7209105387386804) begin
    n1 = ugen(:Saw, 0.0)
    n2 = ugen(:BRF, ugen(:DC, :freq), 800.0, 0.5)
    n3 = ugen(:Saw, 220.0)
    n4 = ugen(:RHPF, n3, 800.0, 0.5)
    n5 = n4 |> fold2(1.0)
    n6 = n5 |> clip2(1.0)
    n7 = ugen(:Saw, :freq; rate = :kr)
    n8 = :freq |> round_q(n7)
    n9 = ugen(:Decimator, n6, n8, 24.0)
    n10 = ugen(:Saw, n9)
    n11 = n2 + n10
    n12 = ugen(:Saw, n11)
    n13 = n12 |> clip2(1.0)
    n14 = n13 |> tanh_drive(1)
    n15 = n14 |> fold2(1.0)
    n16 = n15 |> fold2(1.0)
    n17 = ugen(:RLPF, n1, n16, 0.3)
    n18 = n17 |> fold2(1.0)
    n19 = n18 |> tanh_drive(1)
    n20 = n19 |> fold2(1.0)
    n21 = n20 |> fold2(1.0)
    ugen(:Limiter, ugen(:LeakDC, ugen(:Sanitize, n21)), 0.95)
end

# ressac-genome: {"controls":{"freq":129.44668993128087,"gain":0.5,"release":0.4148026978883561,"sustain":0.7209105387386804},"next_id":25,"nodes":[{"args":[{"id":14,"t":"node"},{"t":"const","v":1.0}],"id":16,"rate":"ar","ugen":"Clip2"},{"args":[{"id":18,"t":"node"}],"id":20,"rate":"ar","ugen":"Saw"},{"args":[{"name":"freq","t":"ctrl"}],"id":12,"rate":"kr","ugen":"Saw"},{"args":[{"id":8,"t":"node"},{"t":"const","v":1.0}],"id":24,"rate":"ar","ugen":"Fold2"},{"args":[{"id":7,"t":"node"},{"t":"const","v":1.0}],"id":8,"rate":"ar","ugen":"Fold2"},{"args":[{"name":"freq","t":"ctrl"},{"t":"const","v":800.0},{"t":"const","v":0.5}],"id":17,"rate":"ar","ugen":"BRF"},{"args":[{"t":"const","v":0.0}],"id":1,"rate":"ar","ugen":"Saw"},{"args":[{"name":"freq","t":"ctrl"},{"id":12,"t":"node"}],"id":19,"rate":"ar","ugen":"Round"},{"args":[{"id":13,"t":"node"},{"t":"const","v":1.0}],"id":22,"rate":"kr","ugen":"Fold2"},{"args":[{"t":"const","v":220.0}],"id":23,"rate":"ar","ugen":"Saw"},{"args":[{"id":2,"t":"node"},{"t":"const","v":1.0}],"id":6,"rate":"ar","ugen":"Fold2"},{"args":[{"id":16,"t":"node"}],"id":11,"rate":"ar","ugen":"Tanh"},{"args":[{"id":17,"t":"node"},{"id":20,"t":"node"}],"id":9,"rate":"ar","ugen":"Mix"},{"args":[{"id":9,"t":"node"}],"id":14,"rate":"ar","ugen":"Saw"},{"args":[{"id":6,"t":"node"}],"id":7,"rate":"ar","ugen":"Tanh"},{"args":[{"id":23,"t":"node"},{"t":"const","v":800.0},{"t":"const","v":0.5}],"id":13,"rate":"ar","ugen":"RHPF"},{"args":[{"id":11,"t":"node"},{"t":"const","v":1.0}],"id":15,"rate":"ar","ugen":"Fold2"},{"args":[{"id":22,"t":"node"},{"t":"const","v":1.0}],"id":21,"rate":"ar","ugen":"Clip2"},{"args":[{"id":1,"t":"node"},{"id":10,"t":"node"},{"t":"const","v":0.3}],"id":2,"rate":"ar","ugen":"RLPF"},{"args":[{"id":15,"t":"node"},{"t":"const","v":1.0}],"id":10,"rate":"ar","ugen":"Fold2"},{"args":[{"id":21,"t":"node"},{"id":19,"t":"node"},{"t":"const","v":24.0}],"id":18,"rate":"ar","ugen":"Decimator"}],"output":24}
