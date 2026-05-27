# Route V — rate-to-voice.
#
# Each frame, measure the spike rate (Hz) of selected neurons (or
# averaged over a population) and fire one continuous oscillator
# voice per source. A neuron firing at 200 spikes/sec drives a
# 200 Hz oscillator — the listener literally hears the spike rate
# as pitch. Four shapes ship as SynthDefs:
#
#   :impulse — raw click train (very buzzy, harmonics)
#   :saw     — sawtooth (harmonic-rich tone)
#   :sin     — pure sine
#   :pulse   — square-ish (width=0.4)
#
# Sources can be either INDIVIDUAL neurons (`sources = [3, 7, 12]`)
# or POPULATIONS — a vector of vectors giving neuron index groups,
# whose mean rate becomes the voice freq:
#
#     sources = [collect(1:12), collect(13:24)]    # 2 populations
#
# Frames overlap (`overlap=2.0` → 50 % cross-fade) so the pitch
# evolves continuously instead of clicking between updates.

# Spike view that spans ALL neurons of a (possibly coupled) reservoir.
# Plain reservoir → its `spikes(r)`. CoupledReservoirs → concatenation
# of every member's spikes, in member order — so the starter can name
# sources like `collect(1:12)` for pop A and `collect(13:24)` for pop B
# even though `length(coupled)` only reports the output member.
_total_length(r) = length(r)
_total_length(r::CoupledReservoirs) = sum(length(m) for m in r.members)

function _gather_spikes!(buf::Vector{Bool}, r)
    spk = spikes(r)
    @inbounds for i in 1:length(spk)
        buf[i] = spk[i]
    end
    return buf
end
function _gather_spikes!(buf::Vector{Bool}, r::CoupledReservoirs)
    off = 0
    @inbounds for m in r.members
        spk = spikes(m)
        for i in 1:length(spk)
            buf[off + i] = spk[i]
        end
        off += length(m)
    end
    return buf
end

"""
    rate_voice(r;
               sources = [1],
               shape = :impulse,
               frames_per_cycle = 16,
               freq_scale = 1.0, freq_offset = 0.0,
               lo_freq = 40.0, hi_freq = 4000.0,
               gain = 0.3, overlap = 2.0,
               drive = 0.0,
               smoothing_frames = 0) -> Pattern{ControlMap}

Map reservoir spike rates to continuous oscillator pitches.

- `sources`           one of:
                        * `Vector{Int}` — each entry is one neuron
                        * `Vector{Vector{Int}}` — each entry is a population
                          (its mean firing rate becomes the voice freq)
                        * `:all` — one voice per neuron
- `shape`             `:impulse` | `:saw` | `:sin` | `:pulse`
- `frames_per_cycle`  how often the freq is refreshed (events per cycle)
- `freq_scale`        multiplier on raw Hz (1.0 = direct; useful to
                      transpose into the audible range)
- `freq_offset`       additive Hz baseline (e.g. always 80 Hz drone + variation)
- `lo_freq`/`hi_freq` clamp the emitted freq into this band
- `gain`, `overlap`   per-voice loudness + envelope cross-fade
- `drive`             reservoir drive (any of the standard forms)
- `smoothing_frames`  if > 0, exponential running average over recent
                      frames smooths the freq jitter
"""
function rate_voice(r;
                    sources = [1],
                    shape::Symbol = :impulse,
                    frames_per_cycle::Int = 16,
                    freq_scale::Real = 1.0,
                    freq_offset::Real = 0.0,
                    lo_freq::Real = 40.0,
                    hi_freq::Real = 4000.0,
                    gain::Real = 0.3,
                    overlap::Real = 2.0,
                    drive = 0.0,
                    smoothing_frames::Int = 0)
    shape in (:impulse, :saw, :sin, :pulse) ||
        throw(ArgumentError("rate_voice shape must be :impulse, :saw, :sin, or :pulse"))
    frames_per_cycle > 0 ||
        throw(ArgumentError("rate_voice frames_per_cycle must be > 0"))
    # N for sources/bounds checks spans ALL neurons (incl. members of a
    # coupled group). N_drive sizes the external-drive vector, which
    # only the output member receives.
    N = _total_length(r)
    N_drive = length(r)

    # Normalise `sources` into a Vector{Vector{Int}} (each entry = one
    # group of neuron indices to average).
    groups = if sources === :all
        [Int[i] for i in 1:N]
    elseif sources isa Vector && !isempty(sources) && sources[1] isa Integer
        [Int[i] for i in sources]
    elseif sources isa Vector
        [collect(Int, g) for g in sources]
    else
        throw(ArgumentError("rate_voice sources must be a Vector of Int, Vector of Vector{Int}, or :all"))
    end
    n_voices = length(groups)
    for grp in groups, i in grp
        1 <= i <= N || throw(BoundsError("neuron $i out of 1..$N"))
    end

    synth = Symbol("rate_$(shape)")
    spc = steps_per_cycle(r)
    drive_source = _make_drive_source(drive, N_drive, spc)
    input = Vector{Float64}(undef, N_drive)
    spike_view = Vector{Bool}(undef, N)
    gain_f = Float64(gain)
    sustain_value = Float64(overlap) / Float64(frames_per_cycle)
    freq_scale_f = Float64(freq_scale)
    freq_offset_f = Float64(freq_offset)
    lo_f = Float64(lo_freq); hi_f = Float64(hi_freq)
    smooth_alpha = smoothing_frames > 0 ?
        2.0 / (smoothing_frames + 1.0) : 1.0
    last_freqs = fill(0.0, n_voices)    # exponential moving average state

    total_steps = Ref(0)
    bin_counts = zeros(Int, n_voices)
    events_by_cycle = Dict{Int, Vector{Event{ControlMap}}}()

    Pattern{ControlMap}((s::Rational, e::Rational) -> begin
        sched = Ressac._LIVE_SCHEDULER[]
        raw_target = if sched === nothing
            ceil(Int, Float64(e) * spc)
        else
            chunk_t = max(0, ceil(Int, sched.last_end_cycles * spc))
            min(chunk_t, ceil(Int, Float64(e) * spc))
        end
        frames_in_target = max(1, ceil(Int, raw_target * frames_per_cycle / spc))
        target_total = max(0,
            round(Int, frames_in_target * spc / frames_per_cycle))

        cps = sched === nothing ? 0.5 : sched.cps

        while total_steps[] < target_total
            c = total_steps[] ÷ spc
            s_in_c = (total_steps[] % spc) + 1
            frame = min(frames_per_cycle - 1,
                        (s_in_c - 1) * frames_per_cycle ÷ spc)
            drive_source(c, s_in_c, input)
            step!(r, input)
            total_steps[] += 1
            _gather_spikes!(spike_view, r)
            @inbounds for (gi, grp) in enumerate(groups)
                hits = 0
                for n in grp
                    spike_view[n] && (hits += 1)
                end
                # Population rate = mean hits across neurons in group.
                # For single-neuron groups (len 1), this is the spike
                # bool. We accumulate the SUM here; convert to Hz on
                # frame flush.
                bin_counts[gi] += hits
            end
            # Frame boundary?
            next_s_in_c = s_in_c + 1
            ended = if next_s_in_c > spc
                true
            else
                next_frame = min(frames_per_cycle - 1,
                                 (next_s_in_c - 1) * frames_per_cycle ÷ spc)
                next_frame != frame
            end
            if ended
                # Frame duration in seconds = (spc / frames_per_cycle) / (spc * cps)
                # = 1 / (frames_per_cycle * cps).
                frame_dur_sec = 1.0 / (frames_per_cycle * cps)
                base = Rational{Int64}(c)
                t_start = base + Rational{Int64}(frame, frames_per_cycle)
                t_stop  = base + Rational{Int64}(frame + 1, frames_per_cycle)
                evs = get!(() -> Event{ControlMap}[], events_by_cycle, c)
                @inbounds for gi in 1:n_voices
                    pop_size = length(groups[gi])
                    # Mean rate per neuron in Hz.
                    rate_hz = pop_size == 0 ? 0.0 :
                              bin_counts[gi] / pop_size / frame_dur_sec
                    raw_freq = rate_hz * freq_scale_f + freq_offset_f
                    # Exponential smoothing across frames.
                    if smoothing_frames > 0 && last_freqs[gi] > 0
                        raw_freq = smooth_alpha * raw_freq +
                                   (1 - smooth_alpha) * last_freqs[gi]
                    end
                    last_freqs[gi] = raw_freq
                    # Drop voice if freq < lo (treat as "silent"). Above
                    # hi, clamp to hi so glitches don't ear-pierce.
                    if raw_freq < lo_f
                        continue
                    end
                    freq = min(raw_freq, hi_f)
                    cm = ControlMap(:s => synth,
                                    :freq => freq,
                                    :gain => gain_f,
                                    :sustain => sustain_value)
                    push!(evs, Event{ControlMap}(t_start, t_stop, cm))
                end
                fill!(bin_counts, 0)
            end
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
