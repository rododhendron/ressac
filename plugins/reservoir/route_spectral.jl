# Route II — spectral cloud (additive resynthesis from reservoir state).
#
# A pragmatic stand-in for true IFFT resynthesis: each "frame" the
# reservoir publishes 16 amplitude values that drive 16 sine partials
# of a `specloud16` voice. Frames fire at `frames_per_cycle` Hz with
# triangular overlap, so the spectrum evolves smoothly as the reservoir
# evolves. Adopts the same Pattern{ControlMap} contract as Route I so
# it slots straight into the existing scheduler.
#
# Why 16 partials and not N: the OSC encoder ships one scalar per key,
# so an event can't carry an N-vector — we'd need bus plumbing for
# arbitrary N. Sixteen is enough to cover a broad spectral palette
# while keeping the SynthDef readable. If you want a different size,
# ship a `specloud<N>.scd` and pass `synth=:specloud<N>` + `bins=<N>`.

"Built-in default amplitude scaling per reservoir kind."
_default_amp_scale(::AdExReservoir) =
    # Map [-70 mV (rest), +20 mV (peak)] roughly into [0, 1].
    v -> clamp((v + 70.0) / 90.0, 0.0, 1.0)
_default_amp_scale(::RECAReservoir) = identity

"""
    spectral_cloud(r; bins=16, frames_per_cycle=8,
                   layout=:logfreq, lo=80, hi=8000,
                   gain=0.3, drive=0.0,
                   amplitude_kind=:auto, amplitude_scale=:auto,
                   overlap=2.0, synth=:specloud16,
                   layout_args=(;)) -> Pattern{ControlMap}

Build a `Pattern{ControlMap}` that fires `frames_per_cycle` additive-
synthesis frames per cycle, each carrying 16 partials whose amplitudes
are sampled from the reservoir state.

- `bins`             number of partials per frame (must match the
                     SynthDef — 16 for the bundled `:specloud16`)
- `frames_per_cycle` frame rate in cycle units
- `layout`           how partial frequencies are spread (reuses Route I
                     layouts: `:logfreq`, `:scale`, `:harmonic`, `:cluster`)
- `lo`, `hi`         layout frequency bounds
- `gain`             top-level voice gain
- `drive`            constant input current per neuron each step
- `amplitude_kind`   which scalar to read from each bin's neuron
                     (`:auto` picks `:V` for AdEx, `:bit` for RECA)
- `amplitude_scale`  optional `Float64 -> Float64` post-transform.
                     `:auto` uses the built-in scaling for the reservoir
                     kind (AdEx → clip-normalised V; RECA → identity).
- `overlap`          envelope sustain multiplier — 1.0 = abutting
                     frames, 2.0 = 50% cross-fade (the default).

`bins ≤ length(r)` is required; bin i reads from neuron index
`round((i-1)·(N-1)/(bins-1) + 1)`, evenly spaced across the reservoir.
"""
function spectral_cloud(r;
                        bins::Int = 16,
                        frames_per_cycle::Int = 8,
                        layout::Symbol = :logfreq,
                        lo::Real = 80.0,
                        hi::Real = 8000.0,
                        gain::Real = 0.3,
                        drive = 0.0,
                        amplitude_kind::Symbol = :auto,
                        amplitude_scale = :auto,
                        overlap::Real = 2.0,
                        synth::Symbol = :specloud16,
                        layout_args::NamedTuple = NamedTuple())
    bins > 0 || throw(ArgumentError("spectral_cloud bins must be > 0"))
    frames_per_cycle > 0 ||
        throw(ArgumentError("spectral_cloud frames_per_cycle must be > 0"))
    N = length(r)
    N >= bins || throw(ArgumentError(
        "reservoir N=$N must be ≥ bins=$bins (cannot subsample $bins from $N)"))

    actual_kind = amplitude_kind === :auto ?
        default_modulator_kind(r) : amplitude_kind
    actual_scale = amplitude_scale === :auto ?
        _default_amp_scale(r) : amplitude_scale

    freqs = compute_layout(layout, bins, lo, hi; layout_args...)
    bin_neurons = bins == 1 ? [1] :
        [round(Int, 1 + (i - 1) * (N - 1) / (bins - 1)) for i in 1:bins]
    # Probe once so kind/neuron errors surface at construction.
    read_state(r, actual_kind, bin_neurons[1])

    spc = steps_per_cycle(r)
    gain_f = Float64(gain)
    sustain_value = Float64(overlap) / Float64(frames_per_cycle)
    drive_source = _make_drive_source(drive, N, spc)
    input = Vector{Float64}(undef, N)
    # Progressive integration — same model as route_spike / route_pool.
    # Each event is emitted at FRAME ONSET with amplitudes snapshotted
    # from the reservoir state right before the first step of that
    # frame. Detected via cycle/frame-change tracking.
    total_steps = Ref(0)
    current_cycle = Ref(-1)
    current_frame = Ref(-1)
    events_by_cycle = Dict{Int, Vector{Event{ControlMap}}}()

    Pattern{ControlMap}((s::Rational, e::Rational) -> begin
        sched = Ressac._LIVE_SCHEDULER[]
        target_total = if sched === nothing
            max(0, ceil(Int, Float64(e) * spc))
        else
            chunk_t = max(0, ceil(Int, sched.last_end_cycles * spc))
            min(chunk_t, ceil(Int, Float64(e) * spc))
        end
        while total_steps[] < target_total
            c = total_steps[] ÷ spc
            s_in_c = (total_steps[] % spc) + 1
            frame = min(frames_per_cycle - 1,
                        (s_in_c - 1) * frames_per_cycle ÷ spc)
            if c != current_cycle[] || frame != current_frame[]
                # Frame onset: snapshot the current amplitudes and emit.
                amps = [Float64(actual_scale(read_state(r, actual_kind, n)))
                        for n in bin_neurons]
                base = Rational{Int64}(c)
                t_start = base + Rational{Int64}(frame, frames_per_cycle)
                t_stop  = base + Rational{Int64}(frame + 1, frames_per_cycle)
                cm = ControlMap(:s => synth,
                                :gain => gain_f,
                                :sustain => sustain_value)
                @inbounds for i in 1:bins
                    cm[Symbol("freq_$i")] = freqs[i]
                    cm[Symbol("amp_$i")]  = amps[i]
                end
                evs = get!(() -> Event{ControlMap}[], events_by_cycle, c)
                push!(evs, Event{ControlMap}(t_start, t_stop, cm))
                current_cycle[] = c
                current_frame[] = frame
            end
            drive_source(c, s_in_c, input)
            step!(r, input)
            total_steps[] += 1
        end
        c_start = floor(Int, Float64(s))
        c_end = max(c_start, ceil(Int, Float64(e)) - 1)
        for k in collect(keys(events_by_cycle))
            k < c_start && delete!(events_by_cycle, k)
        end
        result = Event{ControlMap}[]
        for c in c_start:c_end
            evs = get(events_by_cycle, c, nothing)
            evs === nothing && continue
            for ev in evs
                s <= ev.start < e && push!(result, ev)
            end
        end
        result
    end)
end

"Integrate one cycle, snapshotting reservoir state at each frame
boundary and packing it into a 16-partial ControlMap. Returns the
`frames_per_cycle` events for that cycle, fully positioned in cycle
time so re-queries can slice them without re-integrating."
function _integrate_spectral_cycle(r, input::Vector{Float64},
                                    drive_source::Function,
                                    cycle::Int, spc::Int,
                                    frames_per_cycle::Int,
                                    bin_neurons::Vector{Int},
                                    freqs::Vector{Float64}, bins::Int,
                                    kind::Symbol, scale_fn,
                                    gain_f::Float64,
                                    sustain_value::Float64,
                                    synth::Symbol)
    events = Event{ControlMap}[]
    base = Rational{Int64}(cycle)
    last_step = 0
    for f in 0:(frames_per_cycle - 1)
        t_start = base + Rational{Int64}(f, frames_per_cycle)
        target_step = round(Int, Float64(t_start - base) * spc)
        while last_step < target_step
            drive_source(cycle, last_step + 1, input)
            step!(r, input)
            last_step += 1
        end
        amps = [Float64(scale_fn(read_state(r, kind, n)))
                for n in bin_neurons]
        t_stop = base + Rational{Int64}(f + 1, frames_per_cycle)
        cm = ControlMap(:s => synth,
                        :gain => gain_f,
                        :sustain => sustain_value)
        @inbounds for i in 1:bins
            cm[Symbol("freq_$i")] = freqs[i]
            cm[Symbol("amp_$i")]  = amps[i]
        end
        push!(events, Event{ControlMap}(t_start, t_stop, cm))
    end
    # Drain any remaining steps so the NEXT cycle starts from the
    # right reservoir state.
    while last_step < spc
        drive_source(cycle, last_step + 1, input)
        step!(r, input)
        last_step += 1
    end
    events
end
