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
    resolved_scalar = _resolve_value(val)
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
]

for name in _SUPERDIRT_PARAM_HELPERS
    @eval $(name)(x) = _control_op($(QuoteNode(name)), _overwrite, x)
end

# ---------------------------------------------------------------------
# Scale-aware degree() helper
# ---------------------------------------------------------------------

"""
    _SCALES

Library of scales as offsets in semitones from the root. Common
diatonic + a few "moods" useful for live coding.
"""
const _SCALES = Dict{Symbol,Vector{Int}}(
    :chromatic     => [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
    :major         => [0, 2, 4, 5, 7, 9, 11],
    :minor         => [0, 2, 3, 5, 7, 8, 10],
    :harmonic_minor=> [0, 2, 3, 5, 7, 8, 11],
    :melodic_minor => [0, 2, 3, 5, 7, 9, 11],
    :dorian        => [0, 2, 3, 5, 7, 9, 10],
    :phrygian      => [0, 1, 3, 5, 7, 8, 10],
    :lydian        => [0, 2, 4, 6, 7, 9, 11],
    :mixolydian    => [0, 2, 4, 5, 7, 9, 10],
    :locrian       => [0, 1, 3, 5, 6, 8, 10],
    :pentatonic    => [0, 2, 4, 7, 9],
    :minor_pent    => [0, 3, 5, 7, 10],
    :blues         => [0, 3, 5, 6, 7, 10],
    :whole         => [0, 2, 4, 6, 8, 10],
)

"""
    _CURRENT_SCALE

Mutable global pointing to the current scale name. Mutated by
`:scale <name>`. Defaults to `:chromatic` (so `degree(x) == n(x)`
until the user picks something).
"""
const _CURRENT_SCALE = Ref{Symbol}(:chromatic)

"""
    _scale_offset(degree, scale_name) -> Int

Map a scale degree (0-based) to a semitone offset. Wraps around with
octaves: degree=`7` in a 7-note scale = root one octave up.

Negative degrees go below the root: `-1` is the 7th degree one octave
down.
"""
function _scale_offset(degree::Integer, scale_name::Symbol)
    scale = get(_SCALES, scale_name, _SCALES[:chromatic])
    n = length(scale)
    oct, idx = divrem(Int(degree), n)
    if idx < 0
        idx += n
        oct -= 1
    end
    return scale[idx + 1] + 12 * oct
end

_scale_offset(degree, scale_name::Symbol) = degree  # non-int → passthrough

"""
    degree(x)

Like `n(x)` but interprets the value as a scale degree in the
currently-active scale. `degree(0)` is the root, `degree(2)` is the
3rd of a major scale (2 = degree 2), `degree(7)` is one octave up
from the root, `degree(-1)` is the 7th below.

Combine with `:scale minor` / `:scale pentatonic` / `:scale dorian`
to compose melodies thinking in degrees instead of semitones.
"""
function degree(x)
    if x isa Pattern
        # Map each event's value through the current scale.
        Pattern{ControlMap}((s::Rational, e::Rational) -> begin
            evs_val = x(s, e)
            out = Event{ControlMap}[]
            for ev_v in evs_val
                v_int = _resolve_value(ev_v.value)
                v_int isa Integer || (v_int = try Int(v_int) catch _; 0 end)
                semis = _scale_offset(v_int, _CURRENT_SCALE[])
                push!(out, Event{ControlMap}(ev_v.start, ev_v.stop,
                                              ControlMap(:n => semis)))
            end
            # This pattern of ControlMap will be merged in by _control_op-style
            # logic, but `degree` returns it directly. Wrap as the standard
            # transform on input pattern.
            out
        end)
        # Wrap: combine with input by setting :n
        # (Actually delegate to set(:n, ...) with a transformed pattern.)
        return set(:n, _scale_transform_pattern(x))
    else
        v_int = _resolve_value(x)
        v_int isa Integer || (v_int = try Int(v_int) catch _; 0 end)
        return set(:n, _scale_offset(v_int, _CURRENT_SCALE[]))
    end
end

"""
    _scale_transform_pattern(x) -> Pattern{Int}

Map every event of `x` through the current scale, producing a
`Pattern{Int}` of semitone offsets. Used internally by `degree(x)` to
feed `set(:n, …)`.
"""
function _scale_transform_pattern(x::Pattern)
    Pattern{Int}((s::Rational, e::Rational) -> begin
        out = Event{Int}[]
        for ev in x(s, e)
            v = _resolve_value(ev.value)
            iv = v isa Integer ? v : try Int(v) catch _; 0 end
            push!(out, Event{Int}(ev.start, ev.stop,
                                  _scale_offset(iv, _CURRENT_SCALE[])))
        end
        out
    end)
end
