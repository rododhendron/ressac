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
    return function (p)
        p = _as_pattern(p)
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
# Bare-string val: parse as mini-notation, then route to the
# Pattern overload. Lets users write `set(:cutoff, "<400 800>")`.
set(key::Symbol, s::AbstractString) = set(key, parse_minino(String(s)))

function set(key::Symbol, pat::Pattern)
    return function (p)
        p = _as_pattern(p)
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
                    new_cm[key] = _resolve_value(ev_v.value)
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
    # Auto-parse a string `val` as mini-notation so users can write
    # `set(:cutoff, "<400 800 1600>")` instead of
    # `set(:cutoff, p"<400 800 1600>")`. Single-token strings like
    # `"1000"` round-trip through `_resolve_value` to numeric.
    val = val isa AbstractString ? parse_minino(String(val)) : val
    resolved_scalar = _resolve_value(val)
    return function (p)
        # Auto-lift any of (Pattern | Symbol | AbstractString) so
        # users can drop the `p"…"` prefix:
        #   @d1 "bd hh sn hh" |> gain(0.5)
        #   :bd |> n("0 3 5 7")
        p = _as_pattern(p)
        p isa Pattern || throw(MethodError(_control_op, (key, op, val, p)))
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
                        v_resolved = _resolve_value(ev_v.value)
                        new_cm = copy(ev_in.value)
                        new_cm[key] = haskey(new_cm, key) ?
                                      op(new_cm[key], v_resolved) :
                                      v_resolved
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
                                  op(new_cm[key], resolved_scalar) :
                                  resolved_scalar
                    out[i] = Event{ControlMap}(ev.start, ev.stop, new_cm)
                end
                out
            end)
        end
    end
end

"""
    _resolve_value(v) -> Any

Coerce a value to a useful OSC type. The mini-notation parser stores
every atom as a `Symbol` (so `p"3 2 2 1"` yields `:3, :2, …` and
`p"0.5 1.0"` yields `:0.5, :1.0`). When that value flows into a helper
expecting a number (`n`, `gain`, `release`, …) we'd rather treat it as
the obvious numeric.

Rule: a Symbol that parses cleanly as Int → Int; else as Float64 →
Float64; else stays a Symbol. Non-Symbols pass through unchanged.
"""
function _resolve_value(v::Symbol)
    str = String(v)
    iv = tryparse(Int, str)
    iv !== nothing && return iv
    fv = tryparse(Float64, str)
    fv !== nothing && return fv
    return v
end
_resolve_value(v) = v

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

"""
    nrun(count) -> (Pattern -> ControlPattern)

Shortcut for `p |> n(runp(count))` — iterate through `count`
sample variants (or note offsets) once per cycle. The most common
combo by far, so worth a dedicated name:

```julia
@d1 :supersaw |> nrun(8)        # arpège 0→7 (=  |> n(runp(8)))
@d1 :amen     |> nrun(16)       # cycle through amen:0..amen:15
```
"""
nrun(count::Int) = p -> _as_pattern(p) |> n(runp(count))

"""
    pump(steps_per_cycle=4, depth=0.6) -> (Pattern -> Pattern)

Sidechain-style gain ducking, faked via a per-cycle gain pattern.
Generates `steps_per_cycle` gain values that dip then ramp back:
the first step is the duck floor (`1 - depth`) and the rest of the
cycle ramps linearly back to 1.0 — sounds like a kick is squashing
the chain on every beat.

```julia
@d1 :pad |> pump()         # 4 ducks per cycle, depth 0.6 (default)
@d1 :pad |> pump(8, 0.8)   # 8 ducks per cycle, deeper duck
```

This is NOT true audio sidechain (no actual amplitude follower —
no audio routing exists between Ressac patterns) but it produces
the recognisable "pumping" sound users want. For real sidechain
on SuperCollider side, see the global compressor wiring in the
SuperDirt boot script.
"""
function pump(steps_per_cycle::Int = 4, depth::Real = 0.6)
    n_steps = max(2, steps_per_cycle)
    floor_v = clamp(1.0 - float(depth), 0.0, 1.0)
    # Build a Pattern{Float64} that emits one gain value per step.
    # The first slot is the duck floor; each subsequent slot ramps
    # linearly up toward 1.0 by the end of the cycle.
    Pattern_T = Pattern{Float64}
    return (p::Pattern) -> begin
        gain_pat = Pattern_T((s::Rational, e::Rational) -> begin
            out = Event{Float64}[]
            cyc_start = floor(Int, s)
            cyc_stop  = ceil(Int, e)
            step_dur = Rational{Int64}(1, n_steps)
            for cyc in cyc_start:(cyc_stop - 1)
                for k in 0:(n_steps - 1)
                    a = Rational{Int64}(cyc) + k * step_dur
                    b = a + step_dur
                    a >= e && break
                    b <= s && continue
                    # k=0 is the floor, k=n-1 should be back near 1.0
                    t = k / (n_steps - 1)
                    val = floor_v + (1.0 - floor_v) * t
                    push!(out, Event{Float64}(a, b, val))
                end
            end
            out
        end)
        gain(gain_pat)(p)
    end
end

# ---------------------------------------------------------------------
# Auto-generated SuperDirt param helpers
# ---------------------------------------------------------------------
#
# Every name below becomes a function `<name>(x) = _control_op(:<name>,
# _overwrite, x)` — same shape as the curated helpers above, but for
# SuperDirt params that don't have a custom composition op. Composition
# defaults to overwrite: `attack(0.1) |> attack(0.5)` is `attack=0.5`.
#
# We only auto-generate names that:
#   - aren't Julia keywords (`end`, `begin`, `do`, ...)
#   - aren't already in `_COMBINATOR_NAMES` or otherwise exported by Ressac
#   - aren't likely to shadow Base / common imports (we skip `cut`, `gate`,
#     `loop`, `lock` to play safe — use `set(:cut, …)` for those.)
#
# Users can declare more helpers themselves by calling `_control_op` —
# the function is exported in spirit, just a leading underscore.

"""
    _SUPERDIRT_PARAM_HELPERS

The list of SuperDirt param names auto-defined as overwrite helpers.
"""
const _SUPERDIRT_PARAM_HELPERS = [
    # Pitch
    :freq,
    # Envelope
    :attack, :release, :hold, :sustain, :legato,
    # Filters
    :cutoff, :resonance, :bandq, :bandf, :hcutoff, :hresonance,
    # Distortion / bit-crush
    :crush, :coarse,
    # Modulation
    :accelerate, :vibrato, :tremolorate, :tremolodepth,
    :phaserrate, :phaserdepth,
    # Delay extras (plain :delay is already a hand-curated helper)
    :delaytime, :delayfeedback,
    # Pitch
    :octave, :slide, :pitch1, :pitch2, :pitch3, :detune,
    # Sample window
    :sampleloop, :speedup,
    # Formant / FX
    :vowel, :enhance, :leslie, :leslierate, :lesliespeed,
    # Spatial
    :pan2, :panspan, :panorbit, :panwidth,
    # Compression — SuperDirt orbit-level compressor params.
    # `compress(x)` lowers dynamics. Composition is overwrite, last wins.
    :compress, :compressThreshold, :compressRatio,
]

for name in _SUPERDIRT_PARAM_HELPERS
    @eval $(name)(x) = _control_op($(QuoteNode(name)), _overwrite, x)
end

