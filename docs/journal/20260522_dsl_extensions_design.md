# Sub-project 5 — DSL extensions: pipeline effects + pattern overrides

Status: approved 2026-05-22.

## Goal

Let the user write effect chains and pattern-valued param overrides on top
of the existing `Pattern{Symbol}` DSL, without breaking back-compat:

```julia
@d1 p"kicklourd hh sn hh" |> gain(p"1 0.7 0.5 1") |> lpf(2000)
@d2 p"bd*4" |> gain(0.8) |> gain(1.2) |> every(4, fast(2))
```

## Architecture

Three pieces, one new file:

1. **`ControlMap`** — a `Dict{Symbol,Any}` carrying an event's full OSC
   param set (`:s => :bd, :gain => 0.96, :lpf => 2000`).
2. **`ControlPattern = Pattern{ControlMap}`** — what every effect chain
   produces. Composes with every existing combinator (`fast`, `rev`,
   `every`, `stack`, `cat`, `mask`) because they are generic in `T`.
3. **Effect helpers** — small functions (`gain`, `lpf`, `set`, …) that
   take a scalar OR a pattern and return a `ControlPattern -> ControlPattern`
   transformation. They auto-lift `Pattern{Symbol}` → `ControlPattern` on
   first contact, so user-facing chains never need an explicit type
   conversion.

`Pattern{Symbol}` stays as-is. Mini-notation (`p"bd hh"`) still produces
`Pattern{Symbol}`. The lift happens at the boundary between the
sample-name DSL and the effect DSL.

## File layout

```
src/
├── controls.jl        # NEW: ControlMap, lift, set, helpers, composition
├── scheduler.jl       # ADD: event_to_osc(Event{ControlMap})
└── Ressac.jl          # ADD: include + exports
test/
├── test_controls.jl   # NEW: lift, set, every helper, composition table
└── test_scheduler.jl  # ADD: event_to_osc(ControlMap) — preset + pipe merge
docs/
└── cheatsheet.md      # ADD: "Effects & overrides" section
```

## Data flow

```
p"bd hh"               # Pattern{Symbol}
  |> gain(0.8)         # lifts to ControlPattern, sets :gain = 0.8
  |> gain(1.2)         # composes via × → :gain = 0.96
  |> lpf(2000)         # sets :lpf = 2000
  |> every(4, fast(2)) # generic combinator, T preserved

# Events emitted (single cycle):
#   (0, 1//2, {:s=>:bd, :gain=>0.96, :lpf=>2000})
#   (1//2, 1, {:s=>:hh, :gain=>0.96, :lpf=>2000})

# At dispatch:
#   event_to_osc looks up :s → no instrument match for :bd
#   → /dirt/play s "bd" gain 0.96 lpf 2000
```

When `:s` matches an instrument:

```
p"kicklourd" |> gain(0.5)
# kicklourd preset = {:s=>:bd, :n=>3, :gain=>1.2, :lpf=>200}
# pipe result      = {:gain=>0.5}
#
# Final merge (pipe wins on overlap, preset fills the rest):
#   {:s=>:bd, :n=>3, :gain=>0.5, :lpf=>200}
#                          ^^^ pipe override, preset's 1.2 dropped
# → /dirt/play s "bd" n 3 gain 0.5 lpf 200
```

## `ControlMap` representation

```julia
const ControlMap = Dict{Symbol,Any}
const ControlPattern = Pattern{ControlMap}
```

A plain dict, no wrapper struct. Reasons:

- Compose freely with `merge`, `haskey`, `get` — no custom API to
  remember.
- `Event{ControlMap}` is a normal `Event{T}`, so the existing scheduler
  iteration, pattern combinators, and clipping rules work unchanged.
- The slight cost (Dict allocation per event) is acceptable: events fire
  at most ~16–32/s in normal use, and Julia's small-dict path is fast.

We will revisit if `@profile_workload` shows allocation pressure.

## Lifting `Pattern{Symbol}` → `ControlPattern`

```julia
function _lift_to_control(p::Pattern{Symbol})::ControlPattern
    Pattern{ControlMap}((s, e) -> begin
        out = Event{ControlMap}[]
        for ev in p(s, e)
            cm = _symbol_to_control_map(ev.value)
            push!(out, Event{ControlMap}(ev.start, ev.stop, cm))
        end
        out
    end)
end

# "bd:1" → {:s => :bd, :n => 1}
# "bd"   → {:s => :bd}
function _symbol_to_control_map(sym::Symbol)::ControlMap
    str = String(sym)
    if (idx = findfirst(':', str)) !== nothing
        return ControlMap(:s => Symbol(str[1:idx-1]),
                          :n => parse(Int, str[idx+1:end]))
    end
    return ControlMap(:s => sym)
end
```

Lift is **idempotent** — `_lift_to_control(p::ControlPattern) = p` via a
second method, so chained calls don't double-wrap.

## Helper functions

### Generic primitive

```julia
"""
    set(key::Symbol, val) -> (p -> ControlPattern)

Set `key` to `val` on every event of `p`. `val` is either a scalar (any
type the OSC encoder accepts) or another `Pattern` whose events'
values become the per-event override.

Composition: `set` is always **overwrite** — repeated `set(:k, ...)` in a
chain replaces the previous value entirely.
"""
function set(key::Symbol, val) end
function set(key::Symbol, pat::Pattern) end
```

Two methods: `val::Any` (treated as constant) vs `pat::Pattern` (per-event
arc-intersect).

### Named helpers

Each is a one-line wrapper over the generic primitive plus a per-key
composition op:

```julia
gain(x)  = _control_op(:gain,  *,   x)   # multiplicative, identity 1.0
speed(x) = _control_op(:speed, *,   x)
lpf(x)   = _control_op(:lpf,   min, x)   # take the more restrictive cutoff
hpf(x)   = _control_op(:hpf,   max, x)
pan(x)   = _control_op(:pan,   _last, x) # overwrite
n(x)     = _control_op(:n,     _last, x)
room(x)  = _control_op(:room,  _last, x)
delay(x) = _control_op(:delay, _last, x)
shape(x) = _control_op(:shape, _last, x)
```

`_last(_old, new) = new` makes overwrite a normal binary op so the
combinator engine doesn't need a special branch.

### Composition mechanics

`_control_op(key, op, val)` returns a function `ControlPattern ->
ControlPattern` that, for each event:

1. Resolves `val` to a value `v` for this event's arc (scalar → constant;
   Pattern → arc-intersect, drop events with no overlap)
2. If `:key` is already in the event's ControlMap, replace it with `op(old, v)`
3. Otherwise, set `:key => v`

This produces "compose within the pipe" for free, because each helper
sees the previous helper's output and reapplies its op.

Mixing `set(:gain, x)` with `gain(y)` in the same chain: `set` overwrites,
`gain` composes. The user explicitly chose by typing one or the other.

## Pattern-valued helpers (e.g. `gain(p"1 0.7 0.5 1")`)

When `val` is a Pattern, the helper threads it through `_combine`-style
arc intersection:

- Query both the input pattern and the value pattern over the same arc
- For each input event, find the (possibly multiple) value events that
  overlap, split the input event at those boundaries, and apply the op
  with each value
- Events with no value-event overlap are passed through unchanged
  (the helper is a no-op on that arc)

This matches TidalCycles' `#` semantics.

## Scheduler integration

```julia
function event_to_osc(ev::Event{ControlMap})
    cm = ev.value
    routing = get(cm, :s, nothing)
    final = ControlMap()

    if routing !== nothing
        instr = instrument_info(routing isa Symbol ? routing : Symbol(routing))
        if instr !== nothing
            # Preset is the base; its :s is the literal sample to play
            # (kicklourd → bd, n=3, ...). Pipe's :s was just routing.
            for (k, v) in instr.params
                final[Symbol(k)] = v
            end
        else
            # No matching preset → pipe's :s is the literal sample name.
            final[:s] = routing
        end
    end

    # Pipe overrides everything *except* :s, which is already settled:
    # preset's literal value when an instrument matched, or the routing
    # symbol itself otherwise. A pipe :s is never a per-event override.
    for (k, v) in cm
        k === :s && continue
        final[k] = v
    end

    # Serialize: :s first, then remaining keys alphabetically.
    args = Any[]
    if haskey(final, :s)
        push!(args, "s"); push!(args, _osc_value(final[:s]))
        delete!(final, :s)
    end
    for k in sort!(collect(keys(final)))
        v = _osc_value(final[k])
        v === missing && continue
        push!(args, String(k)); push!(args, v)
    end
    return OSCMessage("/dirt/play", args)
end
```

Subtle case: if a user wants to **change the routing target**, they
`set(:s, :other_thing)`. The pipe's `:s` then drives the preset lookup
(via the final pipe value, since `:s` only goes one direction through the
chain), but it's never shipped as a per-event "override" on top of a
preset that already chose its own `:s`.

Existing `event_to_osc(Event{Symbol})` is untouched — `pure(:bd)` and
mini-notation patterns without effects still ship via the instrument-or-bare
path defined in sub-project 4.

## Live API hookup

`set_pattern!(s, slot, p::Pattern)` already accepts any `Pattern{T}`. No
change needed — `Pattern{ControlMap}` flows through transparently because
the scheduler iterates events generically.

`d!` and `@d1..@d64` are equally agnostic.

## Tests

### `test/test_controls.jl` (new file)

- `_symbol_to_control_map`: `"bd"` and `"bd:1"` cases
- `_lift_to_control`: applied to `pure(:bd)` and `p"bd:1 sn"`; idempotent on ControlPattern input
- `set(:k, scalar)`: every event gets `:k => val`
- `set(:k, pattern)`: arc intersection, multi-value across one cycle
- `set(:k, val) |> set(:k, val2)`: overwrite (last wins)
- `gain(0.5)`: scalar
- `gain(0.5) |> gain(2.0)`: compose × → 1.0
- `gain(p"0.5 1.0")`: pattern-valued, 2 events per cycle each get correct gain
- `lpf(2000) |> lpf(500)`: compose min → 500
- `hpf(100) |> hpf(500)`: compose max → 500
- `pan(0.5) |> pan(0.3)`: overwrite → 0.3
- `gain(2.0)(pure(:bd))`: implicit lift, event payload is ControlMap

### `test/test_scheduler.jl` (extend existing testset)

- `event_to_osc(Event{ControlMap})` with no instrument: args in
  `s, <alpha-sorted>` order
- With instrument preset, no overlap: preset keys present
- With instrument preset + overlap: pipe wins on the overlapping key,
  preset's other keys still present
- ControlMap event containing a `missing`-mapping value drops that key

## Doc updates

`docs/cheatsheet.md` — new "Effects & overrides" section right after
"Instruments & synths":

- Effect chain example
- Helper table (which compose how)
- `set` escape hatch
- Pattern-valued helper example

## Out of scope

- Mini-notation `#` syntax (e.g. `p"bd hh" # gain "1 0.7"`). The Julia
  pipe form is enough.
- `cut`, `orbit`, `begin`, `end`, `crush`, `delaytime`, `delayfeedback`
  — accessible via `set(:k, v)` until someone wants them sugared.
- Per-instrument-param override semantics beyond "pipe wins entirely":
  no per-key opt-in to multiplicative-vs-overwrite for preset+pipe
  interaction.
- TUI integration of effects (autocomplete, `:effects` listing) — that
  belongs in sub-project 6.

## Risks

- **Allocation churn**: ControlMap is a Dict, one per event per cycle.
  Mitigation: the scheduler ships ~16–32 events/s in normal use; we'll
  re-check if `@profile` shows hot allocations.
- **Helper namespace pollution**: `gain`, `pan`, `n`, `speed`, `delay`
  are common names. We export them at module level. Users colliding can
  always `using Ressac: gain as rgain` or fully-qualify.
- **Subtle preset+pipe interaction**: the rule is "pipe touches → pipe
  wins entirely". Future surprise: a user adds `gain(1.0)` (intended as
  a no-op) and silently drops the preset's `gain=1.2`. Documented
  explicitly in the cheatsheet.

## Out-of-scope reminder for sub-project 6

Sub-project 6 takes effects as a given and builds: command-hint widget,
autocomplete in `:`-mode for `:samples` / `:instruments` / `:synths` /
`:guide`, interactive `:guide` modal. Effects metadata (which helpers
exist, their composition op) will be queryable from the runtime.
