# Sub-project 11 — Microtonal + geometric tunings + playground

## Goal

Make Ressac first-class microtonal: any cents-based pitch, any
period (octave or not), any tuning grid (EDO, ratios, fibonacci,
continued fractions, Bohlen-Pierce, etc.). Visualize the active
scale. Compose pitch transforms cleanly with the existing control
pipeline. Plugin-extensible.

## UX decisions (validated)

### `n` / `note` / `scale` — pitch semantics

Three distinct, single-purpose functions:

| Function | Semantics | SuperDirt control | Type |
|---|---|---|---|
| `n(x)` | Sample variant only (file index inside a sample folder) | `:n` | Int |
| `note(x)` | Direct chromatic pitch in semitones from C-1; 60 = middle C; float-friendly | `:note` | Float64 |
| `scale(s)(x)` | Degree-in-a-Scale → cents → semitones | `:note` | Float64 |

```julia
"bd" |> n("0 1 2")             # sample variants 0/1/2
:saw |> note(60.5)             # quarter-tone above middle C
"0 2 4 7" |> scale(myscale)    # degree 0/2/4/7 in myscale
```

**Breaks**: the old overloaded `n(60)` (= "play note 60") becomes
`note(60)`. `degree()` disappears — `scale(s)` subsumes it.

### No global scale

Scales are values; the user holds them in variables or references
them by symbol via the registry. There is no `_CURRENT_SCALE[]`
Ref. Each pattern explicitly carries its scale via `|> scale(...)`.

```julia
myscale = edo(:n19, 19)
"0 2 4 7" |> scale(myscale)            # via variable
"0 2 4 7" |> scale(:bp_lambda)         # via symbol → registry lookup
```

### Last-wins for cascading pitch controls

Cohérent with the existing control composition rules
(`gain(0.5) |> gain(0.8)` keeps 0.8). If the user pipes both
`scale(s)` and `note(...)` on the same pattern, the latter overrides.

### `degree(0)` = root

0-based, TidalCycles convention.

### `Scale` is immutable

Every transform (`scale_stretch`, `transpose`) returns a new
`Scale`. No mutation.

## Core type

```julia
struct Scale
    name::Symbol
    cents::Vector{Float64}    # strictly increasing, starts at 0,
                              # all values < period_cents
    period_cents::Float64     # 1200 = octave; other for BP / xen
end
```

A `Scale` is:
- A set of `cents` offsets within a single period
- A `period_cents` that defines how stacking degrees beyond `length(cents)` wraps

Degree mapping (the central operation):

```julia
function scale_to_semitones(s::Scale, degree::Real)
    n = length(s.cents)
    oct, idx = divrem(Int(degree), n)
    if idx < 0
        idx += n
        oct -= 1
    end
    cents = s.cents[idx + 1] + oct * s.period_cents
    return cents / 100.0   # semitones for SuperDirt :note
end
```

For a non-integer degree (fractional), we linearly interpolate
between adjacent `cents` entries — useful for glissandi.

## Constructors

```julia
edo(name, n)                                         # equal divisions of octave
edo(name, n; period_cents = 1200.0)                  # equal divisions of any period
from_ratios(name, ratios::Vector{<:Real})            # cents = 1200 * log2(r/r₀)
from_cents(name, cents::Vector{<:Real})              # explicit cents list
golden_meantone(name; n_steps = 12)                  # φ-anchored meantone
continued_fraction_scale(name, coeffs)               # convergents of [a₀;a₁,a₂,…]
fibonacci_scale(name; n_steps = 7)                   # Φⁿ ratios
bohlen_pierce(name; variant = :lambda)               # BP variants (:lambda, :dur, :moll)
stern_brocot(name; depth = 5)                        # Stern-Brocot tree depth
```

All return `Scale`. The library scales (~60 12-EDO names — `:major`,
`:minor`, `:dorian`, `:bp_lambda`, etc.) are pre-registered via
these constructors in `core_tuning.jl`.

## Registry + lookup

```julia
const _SCALES = Dict{Symbol, Scale}()
register_scale!(s::Scale)
lookup_scale(name::Symbol) -> Union{Scale, Nothing}
list_scales() -> Vector{Symbol}
```

Plugin contribution via `plugin.toml`:

```toml
[[scales]]
name = "maqam_rast"
cents = [0, 200, 350, 500, 700, 900, 1050]
period_cents = 1200.0
```

Plugin loader parses → `Scale` → `register_scale!`. Last-wins
collision with a warning (same convention as docs/snippets).

## Pattern combinators (Layer 3)

```julia
pat |> scale(s)                # see above; produces :note
pat |> transpose_cents(c)      # shift all notes by c cents
pat |> scale_stretch(factor)   # period *= factor (xen squish)
pat |> bend(curve)             # time-varying pitch bend
                               # curve = continuous Pattern{Float64}
                               # output adds curve(t) cents to :note
```

All combinators operate on the final `:note` control value, so they
chain cleanly with `scale`, `gain`, `lpf`, etc.

## TuningPane — circular visualization

New pane kind `:tuning`. Renders the active scale as a circular
"necklace":
- **360° = one period**, regardless of period_cents (octave or
  tritave look the same shape; only the tick labels differ)
- Each tick = one degree of the scale, positioned at
  `2π * cents[i] / period_cents`
- Tick label shows cents or ratio (toggleable via `r` key)
- Recently-played degrees pulse with `:accent` style
- Bottom of the pane: scale name + period + step count

The pane subscribes to a global `_LAST_NOTES[]` Ref that the
scheduler updates on each event ship (cheap — single Float64 slot
per :note event).

## Ex commands

```
:scale list                         # show registered scales
:tuning edo 19                      # build + register :edo_19
:tuning ratios 1 9/8 5/4 4/3 3/2    # build + register
:tuning bp                          # Bohlen-Pierce shortcut
:vsplit tuning                      # open TuningPane
:vsplit tuning name=bp_lambda       # open showing a specific scale
```

These create scales and register them under sensible names (`edo_19`,
`ratios_1_9_8_…`, `bp_lambda`). They do NOT set any global —
they just make the scale reachable by symbol from the registry.

## Build order

1. **A — Core type + registry** : `src/core_tuning.jl` with `Scale`,
   `register_scale!`, `lookup_scale`, `scale_to_semitones`,
   `_fractional_semitones` (interpolation). Unit tests for the
   degree-mapping math.

2. **B — Constructors** : `edo`, `from_ratios`, `from_cents`, plus
   the geometric helpers (`golden_meantone`,
   `continued_fraction_scale`, `fibonacci_scale`, `bohlen_pierce`,
   `stern_brocot`). Pre-register all 60 existing 12-EDO scales as
   `Scale` values in the registry. Unit tests for each constructor.

3. **C — Refactor `n` / `note` / introduce `scale` control** :
   - `n(x)` keeps producing `:n` Int (sample variant)
   - new `note(x)` produces `:note` Float64 (chromatic semitones)
   - new `scale(s)` returns a control function that maps
     pattern-of-degrees → `:note`
   - delete `degree(x)` and `_CURRENT_SCALE[]`; delete `:scale` ex
     command's "set global" semantics
   - update tests that used `degree` / `:scale <name>`

4. **D — Pattern combinators** : `transpose_cents`, `scale_stretch`,
   `bend`. Unit tests for each.

5. **E — Ex commands** : `:scale list`, `:tuning edo N`,
   `:tuning ratios …`, `:tuning bp` (and a couple other shortcuts).

6. **F — TuningPane** : new `:tuning` PaneImpl in
   `src/pane_tuning.jl`. Circular render with cents labels. Recently-
   played degree highlight via a `_LAST_NOTES` Ref the scheduler
   pushes to.

7. **G — Plugin contribution** : extend `plugin.toml` parser to
   read `[[scales]]`, build `Scale`, register. Test fixture plugin
   with a custom maqam scale.

8. **H — Visual + e2e tests** : add tests in
   `test_visual_integration.jl` covering: `:saw |> note(60.5)`
   produces float `:note`, `pat |> scale(s)` resolves degrees,
   `transpose_cents` adds the shift, TuningPane renders a degree
   tick at the right angle.

## Out of scope (for this sub-project)

- Audio I/O changes — SuperDirt already accepts `:note` as float
- MIDI in/out (separate subsystem)
- Tempo-relative tunings (xenharmonic temporal)
- Polychromaticism (multiple tunings playing simultaneously beyond
  per-pattern scope) — already covered by per-pattern `|> scale(s)`

## Acceptance criteria

- `myscale = edo(:n19, 19); "0 2 4" |> scale(myscale)` plays
  through SuperDirt with the right cents per degree
- Bohlen-Pierce lambda renders correctly in TuningPane as a
  circular tritave
- `pat |> scale(s) |> transpose_cents(50)` produces a quarter-tone
  sharp version of the pattern
- Plugin can contribute `[[scales]]`; user references by symbol
- ~60 existing 12-EDO scale names still work via `scale(:major)`
- No global mutable scale state; every test that uses scales is
  hermetic (no shared global)
- Test suite stays green; visual tests assert TuningPane render
