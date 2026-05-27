@synth :supersaw (freq=220, detune=0.012) (
    saw(:freq) + saw(:freq * (1 + :detune)) + saw(:freq * (1 - :detune))
) * 0.33
