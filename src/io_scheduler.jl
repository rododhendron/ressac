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
    # Synth alias → SC name. `p"wob"` where `wob` is the alias for
    # SynthDef \wob1: ship the SC name and route through /ressac/play
    # so the SynthDef's own defaults apply (SuperDirt has no record
    # of user synths and would reject the bare name).
    sc_name = resolve_synth_name(ev.value)
    if _is_user_synth(sc_name)
        return OSCMessage("/ressac/play", Any[String(sc_name)])
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
    # SuperDirt's machinery). When the `:s` is an alias, ship the
    # resolved SC SynthDef name (the alias is purely client-side).
    target = haskey(final, :s) ? Symbol(final[:s] isa Symbol ? final[:s] : Symbol(final[:s])) : nothing
    sc_target = target === nothing ? nothing : resolve_synth_name(target)
    if sc_target !== nothing && _is_user_synth(sc_target)
        args = Any[String(sc_target)]
        delete!(final, :s)
        _push_kv_args!(args, final)
        return OSCMessage("/ressac/play", args)
    end

    args = Any[]
    if haskey(final, :s)
        s_conv = _osc_value(final[:s])
        s_conv !== missing && (push!(args, "s"); push!(args, s_conv))
        delete!(final, :s)
    end
    _push_kv_args!(args, final)
    return OSCMessage("/dirt/play", args)
end

"""
    _push_kv_args!(args, dict)

Push `(String(k), _osc_value(v))` into `args` for each entry of
`dict`, in alphabetical key order so the serialisation is stable
(SuperDirt parses by key name, but a deterministic order keeps
logs + tests legible). Values that `_osc_value` rejects (returns
`missing`) are dropped silently — they were already `@warn`'d at
conversion time.

Used by both `/ressac/play` and `/dirt/play` branches of
`event_to_osc(::Event{ControlMap})` to serialise the param tail.
The `:s` key is handled separately by the caller (it leads the
arg list and uses different framing per branch) and should be
removed from `dict` before calling.
"""
function _push_kv_args!(args::Vector{Any}, dict::AbstractDict{Symbol,<:Any})
    for k in sort!(collect(keys(dict)))
        v_conv = _osc_value(dict[k])
        v_conv === missing && continue
        push!(args, String(k)); push!(args, v_conv)
    end
    return args
end

"""
    _is_user_synth(name::Symbol) -> Bool

True if `name` is registered as a user-authored synth. Used by
`event_to_osc` to decide between /ressac/play (defaults-honouring)
and /dirt/play (SuperDirt-controlled). Two plugins qualify:

  * `"user-synths"` — saved via :save-synth (typically a .scd SynthDef)
  * `"user-dsl"`    — defined via the `@synth` macro at the REPL or
                      autoloaded from a `.jl` file in plugins/user-synths/

Both produce SynthDefs the user owns and expects to play with their
own parameter defaults, not SuperDirt's auto-injected values.
"""
function _is_user_synth(name::Symbol)
    entry = synth_info(name)
    entry === nothing && return false
    return entry.plugin == "user-synths" || entry.plugin == "user-dsl"
end

event_to_osc(ev::Event) = throw(ArgumentError(
    "No event_to_osc method for Event{$(typeof(ev.value))}; define one."))

"""
    _orbit_for_slot(slot::Symbol) -> Union{Int, Nothing}

Map a pattern slot to a SuperDirt orbit index (0-based). `:d1 → 0`,
`:d2 → 1`, …, `:d12 → 11`. Slots beyond 12 wrap (`:d13 → 0`) so they
still play, sharing an orbit with the lower slot. Anything that isn't
`d<N>` returns `nothing` (won't get an orbit injection).
"""
function _orbit_for_slot(slot::Symbol)
    s = String(slot)
    (length(s) >= 2 && s[1] == 'd') || return nothing
    n = tryparse(Int, SubString(s, 2))
    n === nothing && return nothing
    n < 1 && return nothing
    return (n - 1) % 12
end

"""
    _inject_orbit!(msg::OSCMessage, slot::Symbol) -> OSCMessage

Append `"orbit" => N` to a `/dirt/play` message's args so SuperDirt
routes the event through orbit `N`. No-op for any other address (e.g.
`/ressac/play` — user synths bypass SuperDirt's orbit system). Lets
the per-orbit RMS taps in SC see distinct levels per `@dN` slot.
"""
function _inject_orbit!(msg::OSCMessage, slot::Symbol)
    msg.address == "/dirt/play" || return msg
    orbit = _orbit_for_slot(slot)
    orbit === nothing && return msg
    # Skip if the user already set an orbit explicitly (defensive: today
    # no API exposes this, but if one ever does, respect it).
    for i in 1:2:length(msg.args)-1
        v = msg.args[i]
        if (v isa AbstractString && v == "orbit") || (v isa Symbol && v === :orbit)
            return msg
        end
    end
    push!(msg.args, "orbit"); push!(msg.args, Int32(orbit))
    return msg
end

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
    # ── Snapshot phase (lock held only here) ──
    # Pull the state we need to query into local variables, drain
    # pending pattern swaps, advance last_end_cycles. The lock is then
    # RELEASED before we run user pattern code (which can be slow:
    # deep combinator chains, allocations, regex inside controls) and
    # before we encode + ship OSC bundles. Without this split, every
    # `set_pattern!` / `set_cps!` / `hush!` call from the UI thread
    # would block until a full pattern query completed — eval on a
    # complex chain stutters the audio.
    local cps, t_start, start_cycles, end_cycles, patterns_snapshot
    lock(s.lock) do
        cps = s.cps
        t_start = s.t_start
        end_cycles = (now + s.lookahead) * cps
        # Drain any pending pattern swaps whose apply_at_cycle has arrived.
        to_install = Symbol[]
        for (slot, (_, at)) in pairs(s.pending)
            Float64(at) <= end_cycles && push!(to_install, slot)
        end
        for slot in to_install
            s.patterns[slot] = s.pending[slot][1]
            delete!(s.pending, slot)
        end
        start_cycles = s.last_end_cycles
        # Advance the cursor NOW so any concurrent _step! sees the new
        # boundary; we'll skip the work outside the lock if start>=end.
        if end_cycles > start_cycles
            s.last_end_cycles = end_cycles
            patterns_snapshot = collect(pairs(s.patterns))  # shallow copy
        else
            patterns_snapshot = Pair{Symbol,Pattern}[]
        end
    end
    isempty(patterns_snapshot) && return
    end_cycles > start_cycles || return

    # ── Query + ship phase (no lock) ──
    n_start = floor(Int, start_cycles)
    n_stop  = ceil(Int, end_cycles)
    fired_at_local = Pair{Symbol,Float64}[]
    for (slot, pattern) in patterns_snapshot
        for n in n_start:(n_stop - 1)
            # `Base.invokelatest` lets us call closures defined in
            # plugins loaded AFTER the scheduler task spawned. Without
            # it, world-age limits raise MethodError when a plugin's
            # Pattern is assigned to a slot post-boot (e.g. anything
            # from the reservoir plugin built via `Reservoir.spike_burst`).
            events = Base.invokelatest(pattern,
                                       Rational{Int64}(n),
                                       Rational{Int64}(n + 1))
            for ev in events
                ev_start = Float64(ev.start)
                if start_cycles <= ev_start < end_cycles
                    fire_time = t_start + ev_start / cps
                    msg = _inject_orbit!(event_to_osc(ev), slot)
                    bundle = OSCBundle(fire_time, [msg])
                    send_osc(s.osc, encode(bundle))
                    Threads.atomic_add!(s.events_shipped, 1)
                    push!(fired_at_local, slot => time())
                end
            end
        end
    end
    # Write back `last_fired_at` under lock — small, fast.
    isempty(fired_at_local) && return
    lock(s.lock) do
        for (slot, t) in fired_at_local
            s.last_fired_at[slot] = t
        end
    end
end

# ---------------------------------------------------------------------------
# Public mutators
# ---------------------------------------------------------------------------

"""
    pattern_keys(s::Scheduler) -> Vector{Symbol}

Atomic snapshot of the slot keys currently installed on `s`. Use
this from the UI thread instead of reading `s.patterns` directly:
the scheduler loop mutates the dict under `s.lock`, and a lock-free
read can observe torn state (missing or duplicated keys during
rehash). Returns a fresh `Vector`; safe to sort / mutate.
"""
function pattern_keys(s::Scheduler)
    lock(s.lock) do
        collect(keys(s.patterns))
    end
end

"""
    pattern_get(s::Scheduler, slot::Symbol) -> Union{Pattern, Nothing}

Atomic read of a single slot. Same rationale as [`pattern_keys`](@ref)
— the scheduler loop can be mid-`set_pattern!` when a UI thread reads
the dict, so the get must hold the lock for correctness.
"""
function pattern_get(s::Scheduler, slot::Symbol)
    lock(s.lock) do
        get(s.patterns, slot, nothing)
    end
end

"""
    pattern_snapshot(s::Scheduler) -> Vector{Pair{Symbol,Pattern}}

Atomic snapshot of the full slot-to-pattern map. Used by code that
needs to iterate every active pattern outside the scheduler loop
(e.g. solo / mute helpers that operate on all-but-one slot).
"""
function pattern_snapshot(s::Scheduler)
    lock(s.lock) do
        collect(pairs(s.patterns))
    end
end

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
