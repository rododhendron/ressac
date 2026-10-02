@synth :brin (freq=907.25282575924297, sustain=0.9472118023836007, release=0.8416818630205727) begin
    ugen(:SyncSaw, :freq |> round_q(ugen(:SyncSaw, (:freq |> b_low_shelf(40.0, 1.4850316506096672, 0.0)) + brown(), ugen(:LFNoise1, 4.0; rate = :kr))), 235.05316579657995)
        |> safe()
end

# ressac-genome: {"controls":{"freq":67.25282575924297,"gain":0.5,"release":0.4416818630205727,"sustain":0.2472118023836007},"next_id":12,"nodes":[{"args":[{"name":"freq","t":"ctrl"},{"t":"const","v":40.0},{"t":"const","v":1.4850316506096672},{"t":"const","v":0.0}],"id":5,"rate":"ar","ugen":"BLowShelf"},{"args":[{"name":"freq","t":"ctrl"},{"id":3,"t":"node"}],"id":4,"rate":"ar","ugen":"Round"},{"args":[{"t":"const","v":4.0}],"id":11,"rate":"kr","ugen":"LFNoise1"},{"args":[{"id":5,"t":"node"},{"id":9,"t":"node"}],"id":10,"rate":"ar","ugen":"Mix"},{"args":[],"id":9,"rate":"ar","ugen":"BrownNoise"},{"args":[{"id":10,"t":"node"},{"id":11,"t":"node"}],"id":3,"rate":"ar","ugen":"SyncSaw"},{"args":[{"id":4,"t":"node"},{"t":"const","v":235.05316579657995}],"id":1,"rate":"ar","ugen":"SyncSaw"}],"output":1}
