# Real-time scheduler: queries patterns over a small look-ahead window,
# converts events to OSC bundles with absolute time tags, and ships them
# to the synthesis backend.

"""
    Scheduler{C}(osc; cps=0.5, lookahead=0.05)

Holds the live state of the scheduling loop.

- `osc::C`: any object supporting `send_osc(osc, bytes::Vector{UInt8})`. The
  built-in [`OSCClient`](@ref) is the production choice; tests provide a mock.
- `cps`: cycles per second (tempo).
- `lookahead`: seconds of slack between query time and event fire time.

Use [`start!`](@ref) to launch the loop on a background task, and
[`set_pattern!`](@ref) / [`hush!`](@ref) / [`set_cps!`](@ref) to drive it
live. The mutator entry points lock around `patterns`/`cps` so the loop
thread never sees a torn read.
"""
mutable struct Scheduler{C}
    patterns::Dict{Symbol,Pattern}
    pending::Dict{Symbol,Tuple{Pattern,Rational{Int64}}}
    last_fired_at::Dict{Symbol,Float64}
    cps::Float64
    lookahead::Float64
    osc::C
    running::Threads.Atomic{Bool}
    t_start::Float64
    last_end_cycles::Float64
    lock::ReentrantLock
    events_shipped::Threads.Atomic{Int}
end

function Scheduler(osc; cps::Real = 0.5, lookahead::Real = 0.05)
    cps > 0 || throw(ArgumentError("cps must be positive"))
    lookahead > 0 || throw(ArgumentError("lookahead must be positive"))
    Scheduler{typeof(osc)}(
        Dict{Symbol,Pattern}(),
        Dict{Symbol,Tuple{Pattern,Rational{Int64}}}(),
        Dict{Symbol,Float64}(),
        Float64(cps),
        Float64(lookahead),
        osc,
        Threads.Atomic{Bool}(false),
        0.0,
        0.0,
        ReentrantLock(),
        Threads.Atomic{Int}(0),
    )
end

"""
    schedule_pattern!(s, slot, p, at_cycle::Rational{Int64})

Queue `p` to be installed at `slot` once cycle `at_cycle` enters the
scheduler's lookahead window. Replaces any prior pending entry for the
same slot. Thread-safe.
"""
function schedule_pattern!(s::Scheduler, slot::Symbol, p::Pattern, at_cycle::Rational{Int64})
    lock(s.lock) do
        s.pending[slot] = (p, at_cycle)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Event → OSC mapping
# ---------------------------------------------------------------------------

"""
    event_to_osc(ev::Event) -> OSCMessage

Convert a pattern event to the OSC message that should fire it on the
synthesis backend.

For `Event{Symbol}`, dispatch is two-tier:

1. If `ev.value` matches a registered instrument
   ([`instrument_info`](@ref)), expand the instrument's params (in their
   declared TOML order, `s` first) into a `/dirt/play` arg list. Each value
   is converted through `_osc_value` for OSC type-safety; unsupported types
   log a warning and are dropped.
2. Otherwise, fall back to the bare sample dispatch `("s", name)`.

Override by adding a method for your own event value types.
"""
function event_to_osc(ev::Event{Symbol})
    instr = instrument_info(ev.value)
    if instr !== nothing
        args = Any[]
        for (k, v) in instr.params
            converted = _osc_value(v)
            converted === missing && continue
            push!(args, k)
            push!(args, converted)
        end
        return OSCMessage("/dirt/play", args)
    end
    return OSCMessage("/dirt/play", Any["s", String(ev.value)])
end

"""
    event_to_osc(ev::Event{ControlMap}) -> OSCMessage

Dispatch a ControlMap-carrying event. The `:s` key drives an
instrument-registry lookup: if it matches, the preset's full param set
seeds the final dict (its `:s` is the literal sample to play). The
event's other keys then merge on top — pipe wins entirely on overlap.
If no instrument matches, the event's keys are shipped as-is.

Argument order: `:s` first, then the remaining keys sorted
alphabetically (SuperDirt parses by key name, but stable ordering keeps
tests and logs predictable).

Values that `_osc_value` cannot serialize log a warning and are
dropped from the message.
"""
function event_to_osc(ev::Event{ControlMap})
    cm = ev.value
    routing = get(cm, :s, nothing)
    final = ControlMap()

    if routing !== nothing
        sym = routing isa Symbol ? routing : Symbol(routing)
        instr = instrument_info(sym)
        if instr !== nothing
            for (k, v) in instr.params
                final[Symbol(k)] = v
            end
        else
            final[:s] = routing
        end
    end

    for (k, v) in cm
        k === :s && continue
        final[k] = v
    end

    # Route user-defined synths through /ressac/play to bypass SuperDirt's
    # freq/sustain/gain auto-injection. Pattern events end up using the
    # SynthDef's own defaults unless the user explicitly set the key.
    # Samples + super* synths from SuperDirt keep /dirt/play (they need
    # SuperDirt's machinery).
    target = haskey(final, :s) ? Symbol(final[:s] isa Symbol ? final[:s] : Symbol(final[:s])) : nothing
    if target !== nothing && _is_user_synth(target)
        args = Any[String(target)]
        delete!(final, :s)
        for k in sort!(collect(keys(final)))
            v_conv = _osc_value(final[k])
            v_conv === missing && continue
            push!(args, String(k)); push!(args, v_conv)
        end
        return OSCMessage("/ressac/play", args)
    end

    args = Any[]
    if haskey(final, :s)
        s_conv = _osc_value(final[:s])
        s_conv !== missing && (push!(args, "s"); push!(args, s_conv))
        delete!(final, :s)
    end
    for k in sort!(collect(keys(final)))
        v_conv = _osc_value(final[k])
        v_conv === missing && continue
        push!(args, String(k)); push!(args, v_conv)
    end
    return OSCMessage("/dirt/play", args)
end

"""
    _is_user_synth(name::Symbol) -> Bool

True if `name` is registered as a synth from the user-synths plugin
(authored live via :synth + :save-synth). Used by `event_to_osc` to
decide between /ressac/play (defaults-honouring) and /dirt/play
(SuperDirt-controlled).
"""
function _is_user_synth(name::Symbol)
    entry = synth_info(name)
    entry === nothing && return false
    return entry.plugin == "user-synths"
end

event_to_osc(ev::Event) = throw(ArgumentError(
    "No event_to_osc method for Event{$(typeof(ev.value))}; define one."))

# ---------------------------------------------------------------------------
# Stepping
# ---------------------------------------------------------------------------

"""
    _step!(s::Scheduler, now::Float64)

Process the lookahead window `(last_end_cycles, (now + lookahead) * cps]`:
query every registered pattern **one whole cycle at a time** (so event arcs
come back un-clipped) and fire each event whose natural onset falls in the
new slice. Updates `last_end_cycles` so the next call only touches events
that haven't yet been seen — this is the canonical defence against the
"sub-window re-fire" bug where a single long event gets shipped repeatedly
because each successive lookahead window contains a clipped fragment of it.
"""
function _step!(s::Scheduler, now::Float64)
    lock(s.lock) do
        end_cycles = (now + s.lookahead) * s.cps
        # Drain any pending pattern swaps whose apply_at_cycle has arrived.
        # Two-pass to avoid mutating `s.pending` while iterating it (Julia's
        # Dict iteration order is not guaranteed under concurrent mutation).
        to_install = Symbol[]
        for (slot, (_, at)) in pairs(s.pending)
            Float64(at) <= end_cycles && push!(to_install, slot)
        end
        for slot in to_install
            s.patterns[slot] = s.pending[slot][1]
            delete!(s.pending, slot)
        end
        start_cycles = s.last_end_cycles
        end_cycles > start_cycles || return
        n_start = floor(Int, start_cycles)
        n_stop  = ceil(Int, end_cycles)
        for (slot, pattern) in s.patterns
            for n in n_start:(n_stop - 1)
                events = pattern(Rational{Int64}(n), Rational{Int64}(n + 1))
                for ev in events
                    ev_start = Float64(ev.start)
                    if start_cycles <= ev_start < end_cycles
                        fire_time = s.t_start + ev_start / s.cps
                        bundle = OSCBundle(fire_time, [event_to_osc(ev)])
                        send_osc(s.osc, encode(bundle))
                        Threads.atomic_add!(s.events_shipped, 1)
                        s.last_fired_at[slot] = time()
                    end
                end
            end
        end
        s.last_end_cycles = end_cycles
    end
end

# ---------------------------------------------------------------------------
# Public mutators
# ---------------------------------------------------------------------------

"""
    set_pattern!(s, slot, p)

Install (or replace) the pattern at `slot`. Thread-safe.
"""
function set_pattern!(s::Scheduler, slot::Symbol, p::Pattern)
    lock(s.lock) do
        s.patterns[slot] = p
    end
    return nothing
end

"""
    hush!(s)

Remove every active pattern. The currently-queued lookahead window will
still fire on the synth, but no further events are scheduled.
"""
function hush!(s::Scheduler)
    lock(s.lock) do
        empty!(s.patterns)
    end
    return nothing
end

"""
    unset_pattern!(s, slot)

Remove the pattern at `slot`. No-op if the slot was unset. Thread-safe.
"""
function unset_pattern!(s::Scheduler, slot::Symbol)
    lock(s.lock) do
        delete!(s.patterns, slot)
    end
    return nothing
end

"""
    set_cps!(s, cps)

Change tempo. Must be positive.
"""
function set_cps!(s::Scheduler, cps::Real)
    cps > 0 || throw(ArgumentError("cps must be positive"))
    lock(s.lock) do
        # Preserve the current cycle position across the tempo change.
        # Without this rebase, `last_end_cycles` (expressed in cycles)
        # stays at its old value while `_step!`'s `end_cycles = (now +
        # lookahead) * new_cps` computes a smaller number when slowing
        # down — `end_cycles > start_cycles` then becomes false and
        # no events ship until time catches back up. After a few
        # cps changes the scheduler can be stuck for minutes.
        now = time()
        current_cycles = max(0.0, (now - s.t_start) * s.cps)
        s.cps = Float64(cps)
        # Rebase t_start so (now - t_start) * new_cps == current_cycles.
        s.t_start = now - current_cycles / s.cps
        s.last_end_cycles = current_cycles
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Loop control
# ---------------------------------------------------------------------------

"""
    start!(s::Scheduler)

Launch the scheduling loop on a background task. The loop polls every
`lookahead / 2` seconds; exceptions in a step are logged but do not crash
the loop.
"""
function start!(s::Scheduler)
    s.running[] = true
    s.t_start = time()
    s.last_end_cycles = 0.0
    Threads.@spawn begin
        while s.running[]
            try
                _step!(s, time() - s.t_start)
            catch err
                @warn "Ressac scheduler step failed" exception=(err, catch_backtrace())
            end
            sleep(s.lookahead / 2)
        end
    end
    return nothing
end

"""
    stop!(s::Scheduler)

Signal the loop to exit at the start of its next iteration.
"""
function stop!(s::Scheduler)
    s.running[] = false
    return nothing
end
