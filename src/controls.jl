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
