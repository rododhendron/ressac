+++
examples = ["@d1 p\"hh*8\" |> pan(p\"0.2 0.8\")    # ping-pong", "@d1 p\"bd\" |> pan(0.5)              # dead-center"]
name = "pan"
short = "Stereo position. 0 = left, 0.5 = centre, 1 = right (some setups: -1 to 1)."
tags = []
+++

# pan

Stereo position. 0 = left, 0.5 = centre, 1 = right (some setups: -1 to 1).

Where the sound sits between the speakers: 0 left, 0.5 centre, 1 right. A pan pattern (`pan("0.2 0.8")`) ping-pongs a hi-hat; a slow signal (`pan(sine() |> segment(8))`) drifts it. Keep the kick and the bass centred: low frequencies have no sides.

See also: stereo, jux, fan
