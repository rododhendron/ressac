# Route I — AdEx bursting reservoir → percussive sinebursts
# layout-mapped to a minor pentatonic.
cps!(0.5)

r = Reservoir.adex(N=32, params=Reservoir.ADEX_BURSTING, seed=42)

@d1 Reservoir.spike_burst(r; drive=600.0, layout=:scale, layout_args=(scale=:minor_pentatonic, root=220), burst_dur=1//16) |> gain(0.4)

# Anchor with a kick so the chaos has a pulse
@d2 p"bd ~ ~ ~ bd ~ ~ ~" |> gain(1.3)
@d3 p"hh*8" |> gain(0.25) |> hpf(4000)