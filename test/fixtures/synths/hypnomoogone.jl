# Detuned sine wash — `[freq, freq + 1]` makes two oscillators
# slightly out of tune; the slow 35 Hz LFO offsets the carrier by
# ±33 Hz around (freq + 32). The 1 Hz detune produces a chorus-y
# beating, same as the original .scd's stereo trick.
# Julia broadcast `.+` does what SC's `[a, b] + c` does: add the
# scalar / modulator to every channel.
# T = test  ·  :w <name> = save as  ·  :dsl = cookbook

@synth :hypnomoogone (freq=195, sustain=2, drive=0.3, cut=2000) (auto_env=false,) begin
  sin_osc([:freq, :freq + 1, :freq + 3] .+ 32 .+ 33 * sin_osc(35)) |>
  fold(-0.97, 0.93) |>
  tanh_drive(:drive) |>
  decimator(4000, 7) |>
  moog_ff(lfo(0.68; low=133, high=:cut), 1.1) |>
  b_low_shelf(200, 1, 7) |>
  leak_dc()
end
