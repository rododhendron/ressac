@synth :fm (freq=220, mratio=2, mindex=300) sin_osc(:freq + sin_osc(:freq * :mratio) * :mindex)
