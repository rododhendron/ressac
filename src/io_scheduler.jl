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
# ── Variantes « nom:3 » et effets SuperDirt ────────────────────────
"""
    _split_variant(sym) -> (base::Symbol, idx::Union{Nothing,Int})

`Symbol("sn:3")` → `(:sn, 3)` ; `:sn` → `(:sn, nothing)`. SuperDirt ne
sépare pas lui-même : c'est nous qui envoyons `s sn n 3` (comme Tidal).
"""
function _split_variant(sym::Symbol)
    str = String(sym)
    i = findlast(':', str)
    i === nothing && return (sym, nothing)
    idx = tryparse(Int, str[nextind(str, i):end])
    idx === nothing && return (sym, nothing)
    return (Symbol(str[1:prevind(str, i)]), idx)
end

# Paramètres que SuperDirt applique lui-même (filtres, réverb, delay,
# waveshaping…). Un synth utilisateur qui en porte un doit passer par
# SuperDirt (/dirt/play) — le chemin direct /ressac/play les ignorerait.
const _DIRT_FX_KEYS = Set{Symbol}([
    :lpf, :cutoff, :hpf, :hcutoff, :resonance, :hresonance, :bandf, :bandq,
    :room, :size, :dry, :delay, :delaytime, :delayfeedback, :shape, :crush,
    :coarse, :vowel, :djf, :squiz, :comb, :distort, :triode, :krush, :kcutoff,
    :leslie, :lrate, :lsize, :ring, :ringf, :ringdf, :octer, :octersub,
    :octersubsub, :waveloss, :binshift, :hbrick, :lbrick, :xsdelay, :tsdelay,
    :scram, :enhance, :freeze, :smear, :fshift, :fshiftnote, :fshiftphase,
    :real, :imag, :phaserrate, :phaserdepth, :tremolorate, :tremolodepth,
    :speed, :accelerate, :cut, :legato, :orbit, :attack, :hold, :release,
])

# Défauts déclarés d'un synth utilisateur (`@synth :x (freq=220, …)`),
# depuis les métadonnées du registre. Vide si inconnus.
function _user_synth_params(name::Symbol)
    e = synth_info(name)
    e === nothing && return Dict{String,Any}()
    p = get(e.metadata, "params", nothing)
    p isa AbstractDict ? Dict{String,Any}(String(k) => v for (k, v) in p) : Dict{String,Any}()
end

# Quand un synth utilisateur passe par SuperDirt, on lui injecte son
# propre défaut de freq — sauf si l'événement pilote déjà la hauteur
# (n / note / freq / degree). La durée suit l'événement (`delta`), comme
# pour tout son Tidal : `sustain(x)` ou `legato(x)` pour la fixer.
function _inject_user_synth_defaults!(final::AbstractDict, name::Symbol)
    params = _user_synth_params(name)
    isempty(params) && return final
    pitch_keys = (:n, :note, :freq, :degree)
    if get(params, "freq", nothing) isa Real && !any(k -> haskey(final, k), pitch_keys)
        final[:freq] = params["freq"]
    end
    return final
end

"""
    _timing_args!(args, ev, cps)

Ajoute `cps`, `cycle` et `delta` (durée de l'événement en secondes) au
message, comme Tidal. SuperDirt en déduit `sustain = delta × legato` :
c'est ce qui fait qu'un `n("[0 3] 7")` joue des notes courtes sur `[0 3]`.
Sans `cps` connu (appel hors ordonnanceur) rien n'est ajouté.
"""
function _timing_args!(args::Vector{Any}, ev::Event, cps)
    cps === nothing && return args
    push!(args, "cps"); push!(args, Float32(cps))
    push!(args, "cycle"); push!(args, Float32(ev.start))
    push!(args, "delta"); push!(args, Float32(_event_delta(ev, cps)))
    return args
end
_event_delta(ev::Event, cps) = Float64(ev.stop - ev.start) / Float64(cps)

"""
    _direct_pitch!(final, sc_target)

Synth utilisateur joué en direct (/ressac/play) : SuperDirt n'est pas là
pour traduire `n` / `note` / `octave` / `midinote` en `freq`, on le fait
ici, avec sa convention (note 0 = do 5 = MIDI 60, `octave` 5 par défaut,
`n` vaut `note` pour un synth). Ne s'applique que si le SynthDef déclare
`freq` et que l'événement ne le fixe pas. Les clés de hauteur traduites
sont retirées, sauf celles que le SynthDef déclare lui-même.
"""
function _direct_pitch!(final::AbstractDict, sc_target::Symbol)
    target = _pitch_target(sc_target)
    params = _user_synth_params(sc_target)
    pitch_keys = (:midinote, :note, :n, :octave)
    if target === nothing
        # Pas de hauteur : on retire n / note / … si l'on connaît les
        # paramètres du synth (un SynthDef inconnu reçoit tout tel quel).
        isempty(params) && return final
        for k in pitch_keys
            haskey(params, String(k)) || delete!(final, k)
        end
        return final
    end
    if !haskey(final, target) && any(k -> haskey(final, k), pitch_keys)
        midi = _resolve_value(get(final, :midinote, nothing))
        note = _resolve_value(get(final, :note, get(final, :n, 0)))
        note isa Real || (note = 0)
        if !(midi isa Real)
            octave = _resolve_value(get(final, :octave, 5))
            midi = note + 12 * (octave isa Real ? octave : 5)
        end
        final[target] = target === :midinote ? Float64(midi) :
                        target === :note     ? Float64(note) :
                        440.0 * 2.0^((Float64(midi) - 69) / 12)
    end
    for k in pitch_keys
        k === target && continue
        haskey(params, String(k)) || delete!(final, k)
    end
    return final
end

# Paramètre qui reçoit la hauteur : `pitch = "…"` dans les métadonnées
# (`[synths.<nom>]` de plugin.toml), sinon `freq` si le SynthDef le
# déclare, sinon rien (le synth n'a pas de hauteur).
function _pitch_target(sc_target::Symbol)
    e = synth_info(sc_target)
    e === nothing && return nothing
    explicit = get(e.metadata, "pitch", nothing)
    explicit isa AbstractString && !isempty(explicit) && return Symbol(explicit)
    return haskey(_user_synth_params(sc_target), "freq") ? :freq : nothing
end

# Synth utilisateur joué en direct (/ressac/play) : la durée suit
# l'événement si le SynthDef a un paramètre `sustain` et que l'événement
# ne fixe pas `sustain` lui-même. `legato(x)` multiplie la durée.
function _direct_sustain!(final::AbstractDict, ev::Event, cps, sc_target::Symbol)
    cps === nothing && return final
    haskey(final, :sustain) && return final
    params = _user_synth_params(sc_target)
    haskey(params, "sustain") || return final
    legato = get(final, :legato, 1.0)
    lg = _resolve_value(legato)
    final[:sustain] = _event_delta(ev, cps) * (lg isa Real ? Float64(lg) : 1.0)
    delete!(final, :legato)
    return final
end

function event_to_osc(ev::Event{Symbol}; cps = nothing)
    base, idx = _split_variant(ev.value)
    instr = instrument_info(base)
    if instr !== nothing
        args = Any[]
        for (k, v) in instr.params
            converted = _osc_value(v)
            converted === missing && continue
            push!(args, k)
            push!(args, converted)
        end
        return OSCMessage("/dirt/play", _timing_args!(args, ev, cps))
    end
    # Synth alias → SC name. `p"wob"` where `wob` is the alias for
    # SynthDef \wob1: ship the SC name and route through /ressac/play
    # so the SynthDef's own defaults apply (SuperDirt has no record
    # of user synths and would reject the bare name).
    sc_name = resolve_synth_name(base)
    if _is_user_synth(sc_name)
        final = _direct_sustain!(ControlMap(), ev, cps, sc_name)
        args = Any[String(sc_name)]
        _push_kv_args!(args, final)
        return OSCMessage("/ressac/play", args)
    end
    args = Any["s", String(base)]
    idx === nothing || (push!(args, "n"); push!(args, idx))
    return OSCMessage("/dirt/play", _timing_args!(args, ev, cps))
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
function event_to_osc(ev::Event{ControlMap}; cps = nothing)
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
    # « sn:3 » → s = sn, n = 3 (sauf n explicite).
    if haskey(final, :s)
        base, idx = _split_variant(final[:s] isa Symbol ? final[:s] : Symbol(final[:s]))
        final[:s] = base
        idx === nothing || haskey(final, :n) || (final[:n] = idx)
    end
    target = haskey(final, :s) ? Symbol(final[:s] isa Symbol ? final[:s] : Symbol(final[:s])) : nothing
    sc_target = target === nothing ? nothing : resolve_synth_name(target)
    if sc_target !== nothing && _is_user_synth(sc_target)
        if any(k -> k in _DIRT_FX_KEYS, keys(final))
            # Un effet SuperDirt est demandé : SuperDirt joue le synth
            # (par son nom de SynthDef), avec les défauts du synth pour
            # freq / sustain afin de garder son caractère.
            final[:s] = sc_target
            _inject_user_synth_defaults!(final, sc_target)
        else
            args = Any[String(sc_target)]
            delete!(final, :s)
            _direct_pitch!(final, sc_target)
            _direct_sustain!(final, ev, cps, sc_target)
            _push_kv_args!(args, final)
            return OSCMessage("/ressac/play", args)
        end
    end

    args = Any[]
    if haskey(final, :s)
        s_conv = _osc_value(final[:s])
        s_conv !== missing && (push!(args, "s"); push!(args, s_conv))
        delete!(final, :s)
    end
    _push_kv_args!(args, final)
    return OSCMessage("/dirt/play", _timing_args!(args, ev, cps))
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
                    msg = _inject_orbit!(event_to_osc(ev; cps = cps), slot)
                    bundle = OSCBundle(fire_time, [msg])
                    send_osc(s.osc, encode(bundle))
                    Threads.atomic_add!(s.events_shipped, 1)
                    push!(fired_at_local, slot => time())
                    # Feed the TuningPane's recently-played highlight.
                    # Late-bound: pane_tuning.jl is included after this
                    # file, but the call resolves at run time. Skip if
                    # the event has no :note.
                    if ev.value isa ControlMap && haskey(ev.value, :note)
                        push_played_note!(ev.value[:note])
                    end
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
