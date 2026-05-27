# Route IV — tonal pool.
#
# Maps the N reservoir neurons onto K musical tones, then accumulates
# spikes per bin per frame. Each frame fires ONE event per ACTIVE bin
# (count > 0) with gain proportional to the count of spikes that hit
# that bin during the frame.
#
# Compared to Route I (spike_burst, 1 event per spike, freq = freqs[i])
# this gives a more chord-like, voicing-aware texture: same tone can
# swell or fade as the population coordinates around it, and you get
# only K bins of pitch material rather than N.
#
# Compared to Route II (spectral_cloud, 16 partials of ONE additive
# voice per frame) this gives discrete instrument-like voices (one
# `:sineburst` per bin), better for melodic / harmonic content than
# spectral textures.

"""
    pool_burst(r;
               bins=12, frames_per_cycle=8,
               layout=:scale, lo=110, hi=1760,
               layout_args=(scale=:minor_pentatonic, root=110),
               burst_dur=1//16, gain_per_spike=0.05, max_gain=0.8,
               drive=0.0, synth=:sineburst,
               mapping=:roundrobin) -> Pattern{ControlMap}

Pool N reservoir neurons into K tonal bins. Each frame, count spikes
per bin and emit one `:sineburst` event per active bin where gain ∝
spike count (clamped to `max_gain`). Quiet bins emit nothing.

- `bins`           number of tones in the palette
- `frames_per_cycle` how often counts are tallied + fired
- `layout`         maps bin index → frequency (`:scale`, `:logfreq`, …)
- `gain_per_spike` per-spike gain contribution (added per bin per frame)
- `max_gain`       saturation ceiling so dense bins don't clip
- `mapping`        `:roundrobin` (neuron i → bin ((i-1) % K) + 1) or
                   `:hash` (hash-distributed)

Drive accepts the same forms as `spike_burst` (Real / Vector /
Function / Pattern{Symbol} / Pattern{Float64} / String).
"""
function pool_burst(r;
                    bins::Int = 12,
                    frames_per_cycle::Int = 8,
                    layout::Symbol = :scale,
                    lo::Real = 110.0,
                    hi::Real = 1760.0,
                    layout_args::NamedTuple = (scale = :minor_pentatonic, root = 110),
                    burst_dur::Rational = 1 // 16,
                    gain_per_spike::Real = 0.05,
                    max_gain::Real = 0.8,
                    drive = 0.0,
                    synth::Symbol = :sineburst,
                    mapping::Symbol = :roundrobin)
    bins > 0 || throw(ArgumentError("pool_burst bins must be > 0"))
    frames_per_cycle > 0 ||
        throw(ArgumentError("pool_burst frames_per_cycle must be > 0"))
    N = length(r)
    spc = steps_per_cycle(r)
    freqs = compute_layout(layout, bins, lo, hi; layout_args...)

    bin_of = if mapping === :roundrobin
        Int[((i - 1) % bins) + 1 for i in 1:N]
    elseif mapping === :hash
        Int[(mod(hash(i), bins)) + 1 for i in 1:N]
    else
        throw(ArgumentError("pool_burst mapping must be :roundrobin or :hash"))
    end

    burst_dur_f = Float64(burst_dur)
    gain_per_spike_f = Float64(gain_per_spike)
    max_gain_f = Float64(max_gain)
    drive_source = _make_drive_source(drive, N, spc)
    input = Vector{Float64}(undef, N)

    # Progressive integration — see route_spike.jl for the rationale.
    # Each query advances the reservoir only as far as needed, so the
    # visual scope scrolls smoothly instead of jumping a full cycle
    # at a time. Per-frame counts are accumulated step-by-step and
    # flushed into an event at the frame boundary OR when crossing
    # into a new cycle.
    total_steps = Ref(0)
    bin_counts = zeros(Int, bins)
    events_by_cycle = Dict{Int, Vector{Event{ControlMap}}}()

    Pattern{ControlMap}((s::Rational, e::Rational) -> begin
        # Cap integration to the scheduler's current lookahead chunk
        # so the reservoir advances at wall-clock pace, not in one
        # cycle-sized burst. See route_spike for the rationale.
        sched = Ressac._LIVE_SCHEDULER[]
        raw_target = if sched === nothing
            ceil(Int, Float64(e) * spc)
        else
            chunk_t = max(0, ceil(Int, sched.last_end_cycles * spc))
            min(chunk_t, ceil(Int, Float64(e) * spc))
        end
        # Round target UP to the next frame boundary so the current
        # frame's accumulator is flushed in time for the scheduler to
        # see its event. Pool events fire at frame END.
        frames_in_target = max(1, ceil(Int, raw_target * frames_per_cycle / spc))
        target_total = max(0,
            round(Int, frames_in_target * spc / frames_per_cycle))
        while total_steps[] < target_total
            c = total_steps[] ÷ spc
            s_in_c = (total_steps[] % spc) + 1
            frame = min(frames_per_cycle - 1,
                        (s_in_c - 1) * frames_per_cycle ÷ spc)
            drive_source(c, s_in_c, input)
            step!(r, input)
            total_steps[] += 1
            spk = spikes(r)
            @inbounds for i in 1:length(spk)
                spk[i] && (bin_counts[bin_of[i]] += 1)
            end
            # Is this the LAST step of the frame? If yes, the
            # accumulator is complete — emit and reset.
            next_s_in_c = s_in_c + 1
            ended = if next_s_in_c > spc
                true               # crossed into next cycle → frame ended
            else
                next_frame = min(frames_per_cycle - 1,
                                 (next_s_in_c - 1) * frames_per_cycle ÷ spc)
                next_frame != frame
            end
            if ended
                _emit_pool_frame!(events_by_cycle, c, frame, bin_counts,
                                  frames_per_cycle, freqs, bins,
                                  gain_per_spike_f, max_gain_f,
                                  burst_dur_f, synth)
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

"Flush a single (cycle, frame) accumulator into the events_by_cycle cache."
function _emit_pool_frame!(events_by_cycle::Dict{Int, Vector{Event{ControlMap}}},
                           cycle::Int, frame::Int,
                           bin_counts::Vector{Int},
                           frames_per_cycle::Int,
                           freqs::Vector{Float64}, bins::Int,
                           gain_per_spike::Float64, max_gain::Float64,
                           burst_dur::Float64, synth::Symbol)
    base = Rational{Int64}(cycle)
    t_start = base + Rational{Int64}(frame, frames_per_cycle)
    t_stop  = base + Rational{Int64}(frame + 1, frames_per_cycle)
    evs = get!(() -> Event{ControlMap}[], events_by_cycle, cycle)
    @inbounds for k in 1:bins
        cnt = bin_counts[k]
        cnt == 0 && continue
        g = min(gain_per_spike * cnt, max_gain)
        cm = ControlMap(:s => synth,
                        :freq => freqs[k],
                        :gain => g,
                        :sustain => burst_dur)
        push!(evs, Event{ControlMap}(t_start, t_stop, cm))
    end
    return
end

"Integrate one cycle. For each frame, count spikes per bin and emit
one `:sineburst` event per non-empty bin with gain proportional to
the bin's count (clamped to `max_gain`)."
function _integrate_pool_cycle(r, input::Vector{Float64},
                                drive_source::Function,
                                cycle::Int, spc::Int,
                                frames_per_cycle::Int,
                                bin_of::Vector{Int},
                                freqs::Vector{Float64}, bins::Int,
                                gain_per_spike::Float64,
                                max_gain::Float64,
                                burst_dur::Float64,
                                synth::Symbol)
    events = Event{ControlMap}[]
    base = Rational{Int64}(cycle)
    last_step = 0
    bin_counts = zeros(Int, bins)
    for f in 0:(frames_per_cycle - 1)
        fill!(bin_counts, 0)
        # Compute the step boundary for this frame's END. Rounding
        # mismatches between spc and frames_per_cycle drift across the
        # cycle; this keeps the LAST frame draining everything.
        target = f == frames_per_cycle - 1 ? spc :
                 round(Int, (f + 1) * spc / frames_per_cycle)
        while last_step < target
            drive_source(cycle, last_step + 1, input)
            step!(r, input)
            last_step += 1
            spk = spikes(r)
            @inbounds for i in 1:length(spk)
                spk[i] && (bin_counts[bin_of[i]] += 1)
            end
        end
        t_start = base + Rational{Int64}(f, frames_per_cycle)
        t_stop  = base + Rational{Int64}(f + 1, frames_per_cycle)
        @inbounds for k in 1:bins
            cnt = bin_counts[k]
            cnt == 0 && continue
            g = min(gain_per_spike * cnt, max_gain)
            cm = ControlMap(:s => synth,
                            :freq => freqs[k],
                            :gain => g,
                            :sustain => burst_dur)
            push!(events, Event{ControlMap}(t_start, t_stop, cm))
        end
    end
    events
end
