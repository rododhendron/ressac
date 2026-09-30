+++
examples = []
name = "Reservoir.rate_voice"
short = "Route V — measured spike rate (Hz) → oscillator frequency. A neuron at 200 spikes/s → a sound at 200 Hz. kwargs: sources (Vector{Int}, Vector{Vector{Int}} or :all), shape=:impulse|:saw|:sin|:pulse, frames_per_cycle, freq_scale, freq_offset, lo_freq, hi_freq, gain, overlap, drive, smoothing_frames."
tags = ["reservoir", "route", "rate"]
+++

# Reservoir.rate_voice

Route V — measured spike rate (Hz) → oscillator frequency. A neuron at 200 spikes/s → a sound at 200 Hz. kwargs: sources (Vector{Int}, Vector{Vector{Int}} or :all), shape=:impulse|:saw|:sin|:pulse, frames_per_cycle, freq_scale, freq_offset, lo_freq, hi_freq, gain, overlap, drive, smoothing_frames.
