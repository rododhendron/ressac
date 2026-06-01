# Detuned sine wash — `[freq, freq + 1]` makes two oscillators
# slightly out of tune; the slow 35 Hz LFO offsets the carrier by
# ±33 Hz around (freq + 32). The 1 Hz detune produces a chorus-y
# beating, same as the original .scd's stereo trick.
# Julia broadcast `.+` does what SC's `[a, b] + c` does: add the
# scalar / modulator to every channel.
# T = test  ·  :w <name> = save as  ·  :dsl = cookbook

@synth :maybesomething (freq=195, sustain=1.0) begin
  sin_osc([:freq, :freq + 1] .+ 32 .+ 33 * sin_osc(35)) |>
  env_linen(0.01, :sustain, 0.1)
end
