# Route I — spike → sine burst.
#
# Build a `Pattern{ControlMap}` from a reservoir. Each step that
# produces a spike on neuron `i` emits a percussive event at the
# frequency assigned to `i` by the chosen layout.
#
# Works on any reservoir type via the interface contract.

"""
    spike_burst(r; layout=:logfreq, lo=200, hi=4000,
                burst_dur=1//16, gain=0.5,
                drive=0.0, synth=:sineburst,
                layout_args=(;)) -> Pattern{ControlMap}

Build a percussive Pattern from reservoir `r`'s spikes.

- `layout`     name of a registered layout
- `lo`, `hi`   layout frequency bounds (some layouts ignore — see docs)
- `burst_dur`  `:sustain` value attached to each emitted event (cycles)
- `gain`       per-spike gain
- `drive`      constant background current injected into every neuron
               each step (pA for AdEx; >0.5 = perturb for RECA)
- `synth`      SynthDef name to fire (default `:sineburst`)
- `layout_args` extra kwargs forwarded to the layout function

Internally the pattern keeps a step counter; each query advances the
reservoir forward in cycle time and emits events for spikes falling in
the query window. Backward queries return no new events.
"""
function spike_burst(r;
                     layout::Symbol = :logfreq,
                     lo::Real = 200.0,
                     hi::Real = 4000.0,
                     burst_dur::Rational = 1 // 16,
                     gain::Real = 0.5,
                     drive = 0.0,
                     synth::Symbol = :sineburst,
                     layout_args::NamedTuple = NamedTuple())
    N = length(r)
    spc = steps_per_cycle(r)
    freqs = compute_layout(layout, N, lo, hi; layout_args...)
    burst_dur_f = Float64(burst_dur)
    gain_f = Float64(gain)
    drive_source = _make_drive_source(drive, N, spc)
    input = Vector{Float64}(undef, N)
    # Progressive integration: advance the reservoir step-by-step ONLY
    # as far as the query window requires. The previous design
    # integrated the whole cycle on first query, which gave the visual
    # scope a "freeze 2s, jump 1000 steps" feel. Stepping per-chunk
    # means history grows ~25 steps every scheduler tick (25 ms),
    # producing a smooth scroll in the raster / graph scope.
    #
    # Events are cached PER CYCLE so re-queries of the same window
    # remain idempotent (the scheduler re-queries pattern(n, n+1) on
    # every chunk that overlaps cycle n).
    total_steps = Ref(0)
    events_by_cycle = Dict{Int, Vector{Event{ControlMap}}}()
    Pattern{ControlMap}((s::Rational, e::Rational) -> begin
        # The scheduler always queries `pattern(n, n+1)` per integer
        # cycle, so `e` alone doesn't tell us how much of the cycle has
        # elapsed in wall time. Read `scheduler.last_end_cycles` — that's
        # the current lookahead chunk boundary, updated every ~25 ms.
        # Cap integration to whichever is smaller (chunk vs cycle) so
        # the reservoir advances at the SAME pace as wall clock.
        sched = Ressac._LIVE_SCHEDULER[]
        cycle_target = ceil(Int, Float64(e) * spc)
        target_total = if sched === nothing
            cycle_target
        else
            chunk_target = max(0, ceil(Int, sched.last_end_cycles * spc))
            min(chunk_target, cycle_target)
        end
        while total_steps[] < target_total
            c = total_steps[] ÷ spc
            s_in_c = (total_steps[] % spc) + 1   # 1-based step in cycle
            drive_source(c, s_in_c, input)
            step!(r, input)
            total_steps[] += 1
            spk = spikes(r)
            t_start = Rational{Int64}(c) + Rational{Int64}(s_in_c - 1, spc)
            t_stop  = Rational{Int64}(c) + Rational{Int64}(s_in_c,     spc)
            evs = get!(() -> Event{ControlMap}[], events_by_cycle, c)
            @inbounds for i in 1:N
                spk[i] || continue
                cm = ControlMap(:s => synth,
                                :freq => freqs[i],
                                :gain => gain_f,
                                :sustain => burst_dur_f)
                push!(evs, Event{ControlMap}(t_start, t_stop, cm))
            end
        end
        c_start = floor(Int, Float64(s))
        c_end   = max(c_start, ceil(Int, Float64(e)) - 1)
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

"Integrate one full cycle of the reservoir, collecting one event per
spike. Returns a vector of `Event{ControlMap}` whose start times fill
the cycle uniformly across all `spc` steps."
function _integrate_spike_cycle(r, input::Vector{Float64},
                                drive_source::Function,
                                cycle::Int, spc::Int,
                                freqs::Vector{Float64}, N::Int,
                                gain_f::Float64, burst_dur_f::Float64,
                                synth::Symbol)
    events = Event{ControlMap}[]
    base = Rational{Int64}(cycle)
    for step_idx in 1:spc
        drive_source(cycle, step_idx, input)
        step!(r, input)
        spk = spikes(r)
        t_start = base + Rational{Int64}(step_idx - 1, spc)
        t_stop  = base + Rational{Int64}(step_idx, spc)
        @inbounds for i in 1:N
            spk[i] || continue
            cm = ControlMap(:s => synth,
                            :freq => freqs[i],
                            :gain => gain_f,
                            :sustain => burst_dur_f)
            push!(events, Event{ControlMap}(t_start, t_stop, cm))
        end
    end
    events
end
