# Per-event OSC param map. Used by effect chains and pattern-value
# overrides. See docs/journal/20260522_dsl_extensions_design.md.

"""
    ControlMap

Alias for `Dict{Symbol,Any}`. Every event in an effect-chain pattern
carries one of these as its `value`. Keys are OSC param names
(`:s, :n, :gain, :lpf, ...`); values are anything `_osc_value` can
serialize (or that the user wants to pass through and will be dropped
with a warning at dispatch time).
"""
const ControlMap = Dict{Symbol,Any}

"""
    ControlPattern

Alias for `Pattern{ControlMap}`. The result type of every effect helper.
"""
const ControlPattern = Pattern{ControlMap}

"""
    _symbol_to_control_map(sym) -> ControlMap

Lift a single `Pattern{Symbol}` event value into the ControlMap shape:
`:bd` → `{:s => :bd}`; `Symbol("bd:1")` → `{:s => :bd, :n => 1}`.

Used by `_lift_to_control` to bridge the legacy sample-name DSL with
the new effect DSL. The `:N` suffix split is what the K preview already
does (see `_WORD_RX` in tui_bindings.jl) — same convention, same parse.
"""
function _symbol_to_control_map(sym::Symbol)::ControlMap
    str = String(sym)
    idx = findfirst(':', str)
    if idx === nothing
        return ControlMap(:s => sym)
    end
    return ControlMap(:s => Symbol(str[1:idx-1]),
                      :n => parse(Int, str[idx+1:end]))
end

"""
    _lift_to_control(p::Pattern{Symbol}) -> ControlPattern

Lift each event's symbol value into a ControlMap. Used by effect helpers
to accept either flavour of pattern transparently. Idempotent: lifting
an already-lifted pattern returns it unchanged (no nested wrapping).
"""
function _lift_to_control(p::Pattern{Symbol})::ControlPattern
    Pattern{ControlMap}((s::Rational, e::Rational) -> begin
        inner = p(s, e)
        out = Vector{Event{ControlMap}}(undef, length(inner))
        for (i, ev) in enumerate(inner)
            out[i] = Event{ControlMap}(ev.start, ev.stop,
                                       _symbol_to_control_map(ev.value))
        end
        out
    end)
end

_lift_to_control(p::ControlPattern) = p

"""
    set(key::Symbol, val) -> (Pattern -> ControlPattern)

Curried setter: returns a function that maps a pattern into a
ControlPattern with `key => val` on every event. `set` is **always
overwrite** — a second `set(:key, ...)` in a chain replaces the
previous value entirely (no composition).

If `val` is itself a `Pattern`, see the `set(::Symbol, ::Pattern)`
method.
"""
function set(key::Symbol, val)
    return function (p::Pattern)
        lifted = _lift_to_control(p)
        Pattern{ControlMap}((s::Rational, e::Rational) -> begin
            inner = lifted(s, e)
            out = Vector{Event{ControlMap}}(undef, length(inner))
            for (i, ev) in enumerate(inner)
                new_cm = copy(ev.value)
                new_cm[key] = val
                out[i] = Event{ControlMap}(ev.start, ev.stop, new_cm)
            end
            out
        end)
    end
end

"""
    set(key::Symbol, pat::Pattern) -> (Pattern -> ControlPattern)

Pattern-valued override: for each event in the input pattern, intersect
its arc with every event of `pat`; emit a sub-event for each
intersection carrying that value. Input events with no overlap are
dropped (the value pattern gates the input).

This matches TidalCycles' `#` operator semantics.
"""
function set(key::Symbol, pat::Pattern)
    return function (p::Pattern)
        lifted = _lift_to_control(p)
        Pattern{ControlMap}((s::Rational, e::Rational) -> begin
            evs_in  = lifted(s, e)
            evs_val = pat(s, e)
            out = Event{ControlMap}[]
            for ev_in in evs_in
                for ev_v in evs_val
                    a = max(ev_in.start, ev_v.start)
                    b = min(ev_in.stop,  ev_v.stop)
                    a < b || continue
                    new_cm = copy(ev_in.value)
                    new_cm[key] = ev_v.value
                    push!(out, Event{ControlMap}(a, b, new_cm))
                end
            end
            sort!(out, by = ev -> ev.start)
            out
        end)
    end
end

"""
    _control_op(key, op, val) -> (Pattern -> ControlPattern)

The shared backend for every named helper. Like `set`, but composes
with any existing `key` in each event via `op(old, new)` instead of
overwriting. `val` is either a scalar or a Pattern (arc-intersected
per-event).

If the input event has no value at `key` yet, the new value is set
directly (no composition with a synthetic identity — first-write is
just a write).
"""
function _control_op(key::Symbol, op, val)
    return function (p::Pattern)
        lifted = _lift_to_control(p)
        if val isa Pattern
            Pattern{ControlMap}((s::Rational, e::Rational) -> begin
                evs_in  = lifted(s, e)
                evs_val = val(s, e)
                out = Event{ControlMap}[]
                for ev_in in evs_in
                    for ev_v in evs_val
                        a = max(ev_in.start, ev_v.start)
                        b = min(ev_in.stop,  ev_v.stop)
                        a < b || continue
                        new_cm = copy(ev_in.value)
                        new_cm[key] = haskey(new_cm, key) ?
                                      op(new_cm[key], ev_v.value) :
                                      ev_v.value
                        push!(out, Event{ControlMap}(a, b, new_cm))
                    end
                end
                sort!(out, by = ev -> ev.start)
                out
            end)
        else
            Pattern{ControlMap}((s::Rational, e::Rational) -> begin
                inner = lifted(s, e)
                out = Vector{Event{ControlMap}}(undef, length(inner))
                for (i, ev) in enumerate(inner)
                    new_cm = copy(ev.value)
                    new_cm[key] = haskey(new_cm, key) ?
                                  op(new_cm[key], val) :
                                  val
                    out[i] = Event{ControlMap}(ev.start, ev.stop, new_cm)
                end
                out
            end)
        end
    end
end

"""
    gain(x) -> (Pattern -> ControlPattern)

Multiplicative gain. Chains via `gain(a) |> gain(b) = gain(a * b)`.
`x` is a scalar or a pattern.
"""
gain(x) = _control_op(:gain, *, x)

"""
    lpf(x) — low-pass filter cutoff (Hz). Composes via `min`
    (the more restrictive cutoff wins).
"""
lpf(x) = _control_op(:lpf, min, x)

"""
    hpf(x) — high-pass filter cutoff (Hz). Composes via `max`.
"""
hpf(x) = _control_op(:hpf, max, x)

"""
    speed(x) — sample playback speed. Composes multiplicatively.
"""
speed(x) = _control_op(:speed, *, x)

# Binary "overwrite" op: ignore the old value, take the new one.
# Used as the op for helpers that don't make musical sense to compose
# arithmetically (pan, room, delay, shape, n).
_overwrite(_old, new) = new

"""
    pan(x) — stereo pan, overwrite semantics.
    n(x) — sample variant index, overwrite.
    room(x) — reverb amount, overwrite.
    delay(x) — delay send level, overwrite.
    shape(x) — waveshaping amount, overwrite.

All five last-write-wins inside a chain. They are not multiplicative
because the musical concept doesn't compose that way (you don't want
`pan(0.5) |> pan(0.3)` to mean pan = 0.15).
"""
pan(x)   = _control_op(:pan,   _overwrite, x)
n(x)     = _control_op(:n,     _overwrite, x)
room(x)  = _control_op(:room,  _overwrite, x)
delay(x) = _control_op(:delay, _overwrite, x)
shape(x) = _control_op(:shape, _overwrite, x)
