@synth :broubroup (freq=52.56546024265131, sustain=0.47068522543923264) begin
    n1 = ugen(:Saw, 220.0)
    n2 = ugen(:RHPF, n1, 800.0, 0.5)
    n3 = n2 |> fold2(1.0)
    n4 = n3 |> clip2(1.0)
    n5 = ugen(:Saw, 220.0)
    n6 = ugen(:RHPF, n5, 800.0, 0.5)
    n7 = n6 |> fold2(1.0)
    n8 = n7 |> clip2(1.0)
    n9 = ugen(:Saw, :freq; rate = :kr)
    n10 = :freq |> round_q(n9)
    n11 = ugen(:Decimator, n8, n10, 24.0)
    n12 = ugen(:Saw, n11)
    n13 = n4 + n12
    n14 = ugen(:Saw, n13)
    n15 = n14 |> clip2(1.0)
    n16 = n15 |> tanh_drive(1)
    n17 = n16 |> fold2(1.0)
    n18 = n17 |> fold2(1.0)
    n19 = n18 |> fold2(1.0)
    n20 = n19 |> fold2(1.0)
    ugen(:Limiter, ugen(:LeakDC, ugen(:Sanitize, n20)), 0.95)
end

# ressac-genome: {"controls":{"freq":52.56546024265131,"gain":0.5,"release":0.290578783245645,"sustain":0.47068522543923264},"next_id":27,"nodes":[{"args":[{"id":23,"t":"node"},{"id":4,"t":"node"}],"id":5,"rate":"ar","ugen":"Mix"},{"args":[{"id":19,"t":"node"},{"t":"const","v":1.0}],"id":20,"rate":"ar","ugen":"Fold2"},{"args":[{"id":6,"t":"node"}],"id":12,"rate":"ar","ugen":"Tanh"},{"args":[{"t":"const","v":220.0}],"id":24,"rate":"ar","ugen":"Saw"},{"args":[{"name":"freq","t":"ctrl"}],"id":8,"rate":"kr","ugen":"Saw"},{"args":[{"id":18,"t":"node"},{"t":"const","v":800.0},{"t":"const","v":0.5}],"id":17,"rate":"ar","ugen":"RHPF"},{"args":[{"id":5,"t":"node"}],"id":1,"rate":"ar","ugen":"Saw"},{"args":[{"id":12,"t":"node"},{"t":"const","v":1.0}],"id":19,"rate":"ar","ugen":"Fold2"},{"args":[{"id":25,"t":"node"},{"t":"const","v":1.0}],"id":22,"rate":"kr","ugen":"Fold2"},{"args":[{"id":22,"t":"node"},{"t":"const","v":1.0}],"id":23,"rate":"ar","ugen":"Clip2"},{"args":[{"id":1,"t":"node"},{"t":"const","v":1.0}],"id":6,"rate":"ar","ugen":"Clip2"},{"args":[{"id":15,"t":"node"},{"id":7,"t":"node"},{"t":"const","v":24.0}],"id":9,"rate":"ar","ugen":"Decimator"},{"args":[{"name":"freq","t":"ctrl"},{"id":8,"t":"node"}],"id":7,"rate":"ar","ugen":"Round"},{"args":[{"id":24,"t":"node"},{"t":"const","v":800.0},{"t":"const","v":0.5}],"id":25,"rate":"ar","ugen":"RHPF"},{"args":[{"id":9,"t":"node"}],"id":4,"rate":"ar","ugen":"Saw"},{"args":[{"id":17,"t":"node"},{"t":"const","v":1.0}],"id":13,"rate":"kr","ugen":"Fold2"},{"args":[{"id":13,"t":"node"},{"t":"const","v":1.0}],"id":15,"rate":"ar","ugen":"Clip2"},{"args":[{"id":20,"t":"node"},{"t":"const","v":1.0}],"id":21,"rate":"ar","ugen":"Fold2"},{"args":[{"t":"const","v":220.0}],"id":18,"rate":"ar","ugen":"Saw"},{"args":[{"id":21,"t":"node"},{"t":"const","v":1.0}],"id":26,"rate":"ar","ugen":"Fold2"}],"output":26}
