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
    task::Union{Task,Nothing}        # la boucle lancée par `start!`, pour l'attendre à l'arrêt
end

# Bornes du tempo. `Inf`, `NaN` ou un `1e9` de faute de frappe ne passent
# pas : un cps infini rebase `t_start` à -Inf et le scheduler ne sort plus
# rien jusqu'au redémarrage. 64 cycles/s, c'est 15 360 BPM — au-delà de tout
# usage musical, en deçà de ce qui noie la boucle.
const _CPS_MAX = 64.0

function _check_cps(cps::Real)
    (isfinite(cps) && 0 < cps <= _CPS_MAX) ||
        throw(ArgumentError("cps doit être un nombre fini entre 0 (exclu) et $(_CPS_MAX) — reçu $(cps)"))
    return Float64(cps)
end

# Au-delà de ce retard (secondes), la boucle live ne rattrape pas : après une
# mise en veille ou un long gel, rejouer d'un coup tout ce qui a été manqué
# enverrait des milliers de bundles déjà périmés. On reprend au présent.
const _CATCHUP_MAX = 1.0

function Scheduler(osc; cps::Real = 0.5, lookahead::Real = 0.05)
    cps = _check_cps(cps)
    (isfinite(lookahead) && lookahead > 0) || throw(ArgumentError("lookahead must be positive"))
    Scheduler{typeof(osc)}(
        Dict{Symbol,Pattern}(),
        Dict{Symbol,Tuple{Pattern,Rational{Int64}}}(),
        Dict{Symbol,Float64}(),
        cps,
        Float64(lookahead),
        osc,
        Threads.Atomic{Bool}(false),
        0.0,
        0.0,
        ReentrantLock(),
        Threads.Atomic{Int}(0),
        nothing,
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
# ── Effets SuperDirt ───────────────────────────────────────────────
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
        if _drone_flag(final)
            # Slot en drone : chaque événement module le nœud tenu par SC.
            # Le slot (1er argument) est posé par `_inject_orbit!`, qui
            # seul le connaît. Pas de sustain : le nœud tient tout seul.
            args = Any["", String(SynthDSL.drone_def_name(sc_target))]
            delete!(final, :s); delete!(final, :drone)
            _direct_pitch!(final, sc_target)
            _push_kv_args!(args, final)
            return OSCMessage("/ressac/drone/set", args)
        end
        haskey(final, :drone) && delete!(final, :drone)
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

# Repli : un pattern dont le type d'élément n'est pas connu d'avance
# (`Pattern{Any}` — `slot(1)`, `p"0 1" + 1`, tout ce qui mélange) se joue
# d'après la valeur réelle de chaque événement. Si cette valeur n'a pas de
# forme OSC (un nombre nu, par exemple), l'erreur dit laquelle.
function event_to_osc(ev::Event{T}; cps = nothing) where {T}
    V = typeof(ev.value)
    (V !== T && hasmethod(event_to_osc, Tuple{Event{V}})) ||
        throw(ArgumentError("un événement de valeur $(repr(ev.value)) ($(V)) ne se joue pas tel quel — " *
                            "il manque un son : `s(…)`, `n(…) |> s(…)`, ou un nom de sample"))
    return event_to_osc(Event{V}(ev.start, ev.stop, ev.value); cps = cps)
end

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
    if msg.address == "/ressac/drone/set" && !isempty(msg.args) && msg.args[1] == ""
        msg.args[1] = String(slot)
        return msg
    end
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

`now` is seconds since `t_start`. The live loop does not use this entry
point: it calls [`_tick!`](@ref), which reads the clock under the lock and
bounds the catch-up.
"""
_step!(s::Scheduler, now::Float64) = _advance!(s, () -> now, Inf)

"""
    _tick!(s::Scheduler)

Un pas de la boucle live. L'heure est lue **sous le verrou**, en même temps
que `t_start` et `cps` : un `set_cps!` qui rebase `t_start` entre la lecture
de l'horloge et celle du tempo ferait sinon sauter le curseur de centaines
de cycles. Le rattrapage est borné à `_CATCHUP_MAX` secondes.
"""
_tick!(s::Scheduler) = _advance!(s, () -> time() - s.t_start, _CATCHUP_MAX)

function _advance!(s::Scheduler, clock, catchup::Float64)
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
    skipped = 0.0
    lock(s.lock) do
        cps = s.cps
        t_start = s.t_start
        end_cycles = (clock() + s.lookahead) * cps
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
        # Trop de retard : on saute au présent plutôt que de tout rejouer.
        floor_cycles = end_cycles - (catchup + s.lookahead) * cps
        if start_cycles < floor_cycles
            skipped = floor_cycles - start_cycles
            start_cycles = floor_cycles
        end
        # Advance the cursor NOW so any concurrent step sees the new
        # boundary; we'll skip the work outside the lock if start>=end.
        if end_cycles > start_cycles
            s.last_end_cycles = end_cycles
            patterns_snapshot = collect(pairs(s.patterns))  # shallow copy
        else
            patterns_snapshot = Pair{Symbol,Pattern}[]
        end
    end
    skipped > 0 &&
        _notify!("[WARN] scheduler en retard — $(round(skipped; digits = 1)) cycle(s) sautés, reprise au présent")
    isempty(patterns_snapshot) && return
    end_cycles > start_cycles || return

    # ── Query + ship phase (no lock) ──
    # Chaque slot est isolé : un pattern qui lève (à la requête ou à
    # l'encodage) ne prive pas les autres de leur fenêtre.
    fired_at_local = Pair{Symbol,Float64}[]
    for (slot, pattern) in patterns_snapshot
        try
            _ship_slot!(s, slot, pattern, start_cycles, end_cycles, t_start, cps, fired_at_local)
        catch err
            _evict_faulty_slot!(s, slot, pattern, err)
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

function _ship_slot!(s::Scheduler, slot::Symbol, pattern::Pattern,
                     start_cycles::Float64, end_cycles::Float64,
                     t_start::Float64, cps::Float64,
                     fired::Vector{Pair{Symbol,Float64}})
    for n in floor(Int, start_cycles):(ceil(Int, end_cycles) - 1)
        # `Base.invokelatest` lets us call closures defined in
        # plugins loaded AFTER the scheduler task spawned. Without
        # it, world-age limits raise MethodError when a plugin's
        # Pattern is assigned to a slot post-boot (e.g. anything
        # from the reservoir plugin built via `Reservoir.spike_burst`).
        events = Base.invokelatest(pattern, Rational{Int64}(n), Rational{Int64}(n + 1))
        for ev in events
            ev_start = Float64(ev.start)
            start_cycles <= ev_start < end_cycles || continue
            fire_time = t_start + ev_start / cps
            msg = _inject_orbit!(event_to_osc(ev; cps = cps), slot)
            msg.address == "/ressac/drone/set" && _drone_mirror!(slot, msg)
            send_osc(s.osc, encode(OSCBundle(fire_time, [msg])))
            Threads.atomic_add!(s.events_shipped, 1)
            push!(fired, slot => time())
            # Feed the TuningPane's recently-played highlight.
            # Late-bound: pane_tuning.jl is included after this
            # file, but the call resolves at run time.
            if ev.value isa ControlMap
                note = get(ev.value, :note, nothing)
                note isa Real && push_played_note!(note)
            end
        end
    end
    return nothing
end

# Un slot dont le pattern lève est retiré — sauf s'il a déjà été remplacé
# entre-temps — et le joueur est prévenu une fois, pas à chaque tick.
function _evict_faulty_slot!(s::Scheduler, slot::Symbol, pattern::Pattern, err)
    evicted = lock(s.lock) do
        if get(s.patterns, slot, nothing) === pattern
            delete!(s.patterns, slot)
            true
        else
            false
        end
    end
    evicted || return nothing
    _drone_slot_release!(slot)
    why = first(sprint(showerror, err), 200)
    _notify!("[ERROR] @$(slot) coupé — son pattern a levé : " * why * " (réévalue-le pour le relancer)")
    _notify_fault!(slot, why)
    return nothing
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
    # Un drone tenu par ce slot repart de zéro avec le nouveau pattern
    # (son premier événement recrée le nœud) : on relâche l'ancien.
    _drone_slot_release!(slot)
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
    _drone_slots_release!()
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
    _drone_slot_release!(slot)
    return nothing
end

"""
    set_cps!(s, cps)

Change tempo. `cps` doit être fini, strictement positif et au plus `_CPS_MAX`.
"""
function set_cps!(s::Scheduler, cps::Real)
    cps = _check_cps(cps)
    lock(s.lock) do
        # La position en cycles est conservée à travers le changement :
        # on rebase `t_start` pour que (now - t_start) * nouveau_cps donne
        # le même cycle qu'avant. Le curseur `last_end_cycles`, lui, est
        # déjà exprimé en cycles : il reste où il est. Le ramener à
        # `current_cycles` ferait réexpédier ce que le lookahead a déjà
        # envoyé (un flam à chaque coup de tap-tempo).
        now = time()
        current_cycles = max(0.0, (now - s.t_start) * s.cps)
        s.cps = cps
        s.t_start = now - current_cycles / s.cps
        s.last_end_cycles = max(s.last_end_cycles, current_cycles)
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
the loop. No-op if the loop is already running.
"""
function start!(s::Scheduler)
    # Un seul démarrage : deux boucles sur le même scheduler se
    # partageraient le curseur.
    Threads.atomic_cas!(s.running, false, true) === false || return nothing
    lock(s.lock) do
        s.t_start = time()
        s.last_end_cycles = 0.0
    end
    s.task = Threads.@spawn begin
        while s.running[]
            try
                _tick!(s)
            catch err
                _notify!("[ERROR] scheduler : " * first(sprint(showerror, err), 200))
            end
            sleep(s.lookahead / 2)
        end
    end
    return nothing
end

"""
    stop!(s::Scheduler; wait_for = 0)

Signal the loop to exit at the start of its next iteration. With
`wait_for > 0`, wait up to that many seconds for the loop task to finish
and return whether it did.
"""
function stop!(s::Scheduler; wait_for::Real = 0)
    s.running[] = false
    task = s.task
    (task === nothing || wait_for <= 0) && return nothing
    return timedwait(() -> istaskdone(task), wait_for) === :ok
end
