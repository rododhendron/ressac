# DSL extensions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users write effect chains and pattern-valued OSC param overrides on top of the existing pattern DSL (`p"bd hh" |> gain(0.8) |> lpf(2000)`).

**Architecture:** A new event payload type `ControlMap = Dict{Symbol,Any}` carries multi-param OSC dispatches. `Pattern{Symbol}` stays as-is; effect helpers auto-lift to `Pattern{ControlMap}` on first contact. Per-helper composition (`gain` ×, `lpf` min, etc.). At dispatch, the instrument-preset lookup seeds the param dict; the pipe wins entirely on every overlapping key.

**Tech Stack:** Julia 1.10+, existing Ressac module structure (`src/*.jl`), `Test.jl`, no new deps.

**Spec:** `docs/journal/20260522_dsl_extensions_design.md`

---

## File layout

```
src/
├── controls.jl                       # NEW — ControlMap + lift + set + helpers
├── scheduler.jl                      # MODIFY — event_to_osc(Event{ControlMap})
├── plugin_handlers.jl                # MODIFY — add _osc_value(::Symbol)
└── Ressac.jl                         # MODIFY — include, exports, precompile
test/
├── test_controls.jl                  # NEW
├── test_scheduler.jl                 # MODIFY — extend the existing @testset
└── runtests.jl                       # MODIFY — include the new file
docs/
└── cheatsheet.md                     # MODIFY — Effects & overrides section
```

---

### Task 1: ControlMap alias + symbol→ControlMap shim

**Files:**
- Create: `src/controls.jl`
- Test: `test/test_controls.jl`
- Modify: `test/runtests.jl` (wire the new test file)

- [ ] **Step 1: Wire the new test file**

Edit `test/runtests.jl`, append `include("test_controls.jl")` after the last `include`:

```julia
    include("test_plugin_handlers.jl")
    include("test_controls.jl")
end
```

- [ ] **Step 2: Write the failing test**

Create `test/test_controls.jl`:

```julia
using Test
using Ressac

@testset "controls" begin
    @testset "ControlMap alias resolves to Dict{Symbol,Any}" begin
        cm = Ressac.ControlMap(:s => :bd, :gain => 0.8)
        @test cm isa Dict{Symbol,Any}
        @test cm[:s] === :bd
        @test cm[:gain] === 0.8
    end

    @testset "_symbol_to_control_map plain symbol → :s only" begin
        cm = Ressac._symbol_to_control_map(:bd)
        @test cm == Dict{Symbol,Any}(:s => :bd)
    end

    @testset "_symbol_to_control_map bd:1 → :s + :n" begin
        cm = Ressac._symbol_to_control_map(Symbol("bd:1"))
        @test cm[:s] === :bd
        @test cm[:n] === 1
    end

    @testset "_symbol_to_control_map bd:12 (multi-digit)" begin
        cm = Ressac._symbol_to_control_map(Symbol("snares:12"))
        @test cm[:s] === :snares
        @test cm[:n] === 12
    end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`
Expected: FAIL with "UndefVarError: ControlMap" or "UndefVarError: _symbol_to_control_map"

- [ ] **Step 4: Write minimal implementation**

Create `src/controls.jl`:

```julia
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
```

Edit `src/Ressac.jl`, add `include("controls.jl")` between `algebra.jl` and `mininotation.jl`:

```julia
include("core.jl")
include("combinators.jl")
include("algebra.jl")
include("controls.jl")
include("mininotation.jl")
```

(Order matters: controls.jl depends on Pattern from core, algebra extends Base ops, controls is the next layer up.)

- [ ] **Step 5: Run test to verify it passes**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: `Test Summary: | Pass  Total  Time` showing 455+ passes (452 baseline + 4 new).

- [ ] **Step 6: Commit**

```bash
git add src/controls.jl src/Ressac.jl test/test_controls.jl test/runtests.jl
git commit -m "$(cat <<'EOF'
controls: ControlMap alias + _symbol_to_control_map

Foundations for sub-project 5. ControlMap is the new event payload
that lets a single event carry multiple OSC params. The shim splits
"bd:1" into {:s => :bd, :n => 1} so legacy sample-bank syntax keeps
working when lifted into the effect DSL.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `_lift_to_control` with idempotency

**Files:**
- Modify: `src/controls.jl`
- Modify: `test/test_controls.jl`

- [ ] **Step 1: Write the failing test**

Append to `test/test_controls.jl` inside the `@testset "controls"`:

```julia
    @testset "_lift_to_control(Pattern{Symbol}) yields ControlPattern" begin
        p = pure(:bd)
        lifted = Ressac._lift_to_control(p)
        @test lifted isa Ressac.ControlPattern
        evs = lifted(0//1, 1//1)
        @test length(evs) == 1
        @test evs[1].value == Dict{Symbol,Any}(:s => :bd)
        @test evs[1].start == 0//1
        @test evs[1].stop  == 1//1
    end

    @testset "_lift_to_control splits :N suffix" begin
        p = pure(Symbol("snares:3"))
        lifted = Ressac._lift_to_control(p)
        evs = lifted(0//1, 1//1)
        @test evs[1].value == Dict{Symbol,Any}(:s => :snares, :n => 3)
    end

    @testset "_lift_to_control is idempotent on ControlPattern" begin
        cp = Ressac._lift_to_control(pure(:bd))
        @test Ressac._lift_to_control(cp) === cp
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`
Expected: FAIL with "UndefVarError: _lift_to_control"

- [ ] **Step 3: Implement**

Append to `src/controls.jl`:

```julia
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: PASS (458+ tests).

- [ ] **Step 5: Commit**

```bash
git add src/controls.jl test/test_controls.jl
git commit -m "$(cat <<'EOF'
controls: _lift_to_control(Pattern{Symbol}) → ControlPattern

Bridge between the legacy sample-name DSL and the new effect DSL.
Idempotent on ControlPattern input so chained helpers can call it
freely without nested wrapping.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `set(:key, scalar)` primitive

**Files:**
- Modify: `src/controls.jl`
- Modify: `test/test_controls.jl`

- [ ] **Step 1: Write the failing test**

Append inside the `@testset "controls"`:

```julia
    @testset "set(:k, scalar) on Pattern{Symbol} via auto-lift" begin
        p = pure(:bd) |> Ressac.set(:gain, 0.8)
        @test p isa Ressac.ControlPattern
        evs = p(0//1, 1//1)
        @test evs[1].value == Dict{Symbol,Any}(:s => :bd, :gain => 0.8)
    end

    @testset "set(:k, scalar) chained overwrites" begin
        p = pure(:bd) |> Ressac.set(:gain, 0.8) |> Ressac.set(:gain, 0.3)
        evs = p(0//1, 1//1)
        @test evs[1].value[:gain] == 0.3   # last write wins for set
        @test evs[1].value[:s] === :bd
    end

    @testset "set(:k, scalar) preserves other keys" begin
        p = pure(:bd) |> Ressac.set(:gain, 0.8) |> Ressac.set(:lpf, 200)
        evs = p(0//1, 1//1)
        @test evs[1].value[:gain] == 0.8
        @test evs[1].value[:lpf]  == 200
        @test evs[1].value[:s]    === :bd
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`
Expected: FAIL with "UndefVarError: set"

- [ ] **Step 3: Implement**

Append to `src/controls.jl`:

```julia
"""
    set(key::Symbol, val) -> (Pattern -> ControlPattern)

Curried setter: returns a function that maps a pattern into a
ControlPattern with `key => val` on every event. `set` is **always
overwrite** — a second `set(:key, ...)` in a chain replaces the
previous value entirely (no composition).

If `val` is itself a `Pattern`, see the next method.
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: PASS (461+ tests).

- [ ] **Step 5: Commit**

```bash
git add src/controls.jl test/test_controls.jl
git commit -m "$(cat <<'EOF'
controls: set(:key, scalar) primitive

Always-overwrite setter. Auto-lifts Pattern{Symbol} so users can chain
without manual conversion. set is the generic escape hatch for any OSC
param that doesn't have a named helper.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `set(:key, ::Pattern)` — pattern-valued override

**Files:**
- Modify: `src/controls.jl`
- Modify: `test/test_controls.jl`

- [ ] **Step 1: Write the failing test**

Append:

```julia
    @testset "set(:k, pattern) — pattern-valued override" begin
        # Gain pattern with 2 events per cycle: [0, 1/2): 0.5, [1/2, 1): 1.0
        gain_pat = parse_minino("0.5 1.0")  # Pattern{Float64}-equivalent
        # parse_minino returns Pattern{Symbol}. We need a Pattern{Float64}
        # for this test. Build it manually:
        gp = Pattern{Float64}((s, e) -> begin
            evs = Event{Float64}[]
            n_start = floor(Int, s)
            n_stop  = ceil(Int, e)
            for n in n_start:(n_stop - 1)
                base = Rational{Int64}(n)
                push!(evs, Event{Float64}(max(base, s),         min(base + 1//2, e), 0.5))
                push!(evs, Event{Float64}(max(base + 1//2, s), min(base + 1//1, e), 1.0))
            end
            filter!(ev -> ev.start < ev.stop, evs)
            evs
        end)
        p = pure(:bd) |> Ressac.set(:gain, gp)
        evs = p(0//1, 1//1)
        @test length(evs) == 2
        # First half: gain = 0.5
        @test evs[1].value[:s]    === :bd
        @test evs[1].value[:gain] == 0.5
        @test evs[1].start == 0//1
        @test evs[1].stop  == 1//2
        # Second half: gain = 1.0
        @test evs[2].value[:gain] == 1.0
        @test evs[2].start == 1//2
        @test evs[2].stop  == 1//1
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`
Expected: FAIL with `MethodError: no method matching set(::Symbol, ::Pattern{Float64})` (or similar — only the scalar method exists).

- [ ] **Step 3: Implement**

Append to `src/controls.jl`:

```julia
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: PASS (462+ tests).

- [ ] **Step 5: Commit**

```bash
git add src/controls.jl test/test_controls.jl
git commit -m "$(cat <<'EOF'
controls: set(:key, ::Pattern) — pattern-valued override

Arc-intersect each input event with each value-pattern event and emit
sub-events carrying the value-event's value. Input events with no
overlap are dropped (value pattern gates the input). Matches Tidal's #
operator semantics.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `_control_op` helper + `gain` (compose ×)

**Files:**
- Modify: `src/controls.jl`
- Modify: `test/test_controls.jl`

- [ ] **Step 1: Write the failing test**

Append:

```julia
    @testset "gain(scalar) sets :gain on first hit" begin
        p = pure(:bd) |> Ressac.gain(0.8)
        evs = p(0//1, 1//1)
        @test evs[1].value[:gain] == 0.8
        @test evs[1].value[:s]    === :bd
    end

    @testset "gain ∘ gain composes via multiplication" begin
        p = pure(:bd) |> Ressac.gain(0.8) |> Ressac.gain(1.2)
        evs = p(0//1, 1//1)
        @test evs[1].value[:gain] ≈ 0.96
    end

    @testset "gain(pattern) — value pattern" begin
        gp = Pattern{Float64}((s, e) -> begin
            n = floor(Int, s)
            base = Rational{Int64}(n)
            evs = [Event{Float64}(max(base, s),         min(base + 1//2, e), 0.5),
                   Event{Float64}(max(base + 1//2, s), min(base + 1//1, e), 1.0)]
            filter!(ev -> ev.start < ev.stop, evs)
            evs
        end)
        p = pure(:bd) |> Ressac.gain(gp)
        evs = p(0//1, 1//1)
        @test length(evs) == 2
        @test evs[1].value[:gain] == 0.5
        @test evs[2].value[:gain] == 1.0
    end

    @testset "gain(pattern) ∘ gain(scalar) composes (multiply)" begin
        gp = Pattern{Float64}((s, e) -> [
            Event{Float64}(0//1, 1//1, 0.5),
        ])
        p = pure(:bd) |> Ressac.gain(gp) |> Ressac.gain(2.0)
        evs = p(0//1, 1//1)
        @test evs[1].value[:gain] == 1.0
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`
Expected: FAIL with "UndefVarError: gain"

- [ ] **Step 3: Implement**

Append to `src/controls.jl`:

```julia
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: PASS (466+ tests).

- [ ] **Step 5: Commit**

```bash
git add src/controls.jl test/test_controls.jl
git commit -m "$(cat <<'EOF'
controls: _control_op + gain (multiplicative compose)

_control_op is the shared backend for every named helper — takes the
per-key composition function (× for gain, min for lpf, etc.). gain
chains multiplicatively: gain(0.8) |> gain(1.2) yields 0.96. First
write is a plain set (no synthetic identity).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `lpf` (min), `hpf` (max), `speed` (×)

**Files:**
- Modify: `src/controls.jl`
- Modify: `test/test_controls.jl`

- [ ] **Step 1: Write the failing test**

Append:

```julia
    @testset "lpf composes via min (most restrictive cutoff wins)" begin
        p = pure(:bd) |> Ressac.lpf(2000) |> Ressac.lpf(500)
        evs = p(0//1, 1//1)
        @test evs[1].value[:lpf] == 500
    end

    @testset "lpf first write just sets" begin
        p = pure(:bd) |> Ressac.lpf(2000)
        evs = p(0//1, 1//1)
        @test evs[1].value[:lpf] == 2000
    end

    @testset "hpf composes via max" begin
        p = pure(:bd) |> Ressac.hpf(100) |> Ressac.hpf(500)
        evs = p(0//1, 1//1)
        @test evs[1].value[:hpf] == 500
    end

    @testset "speed composes via multiplication" begin
        p = pure(:bd) |> Ressac.speed(2.0) |> Ressac.speed(0.5)
        evs = p(0//1, 1//1)
        @test evs[1].value[:speed] ≈ 1.0
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`
Expected: FAIL with "UndefVarError: lpf" or similar.

- [ ] **Step 3: Implement**

Append to `src/controls.jl`:

```julia
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: PASS (470+ tests).

- [ ] **Step 5: Commit**

```bash
git add src/controls.jl test/test_controls.jl
git commit -m "$(cat <<'EOF'
controls: lpf (min), hpf (max), speed (×) helpers

Three more helpers built on _control_op. lpf takes min so the most
restrictive cutoff wins; hpf takes max for the same reason; speed is
multiplicative like gain.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Overwrite helpers (`pan`, `n`, `room`, `delay`, `shape`)

**Files:**
- Modify: `src/controls.jl`
- Modify: `test/test_controls.jl`

- [ ] **Step 1: Write the failing test**

Append:

```julia
    @testset "pan overwrites (last write wins)" begin
        p = pure(:bd) |> Ressac.pan(0.5) |> Ressac.pan(0.3)
        evs = p(0//1, 1//1)
        @test evs[1].value[:pan] == 0.3
    end

    @testset "n, room, delay, shape are overwrite" begin
        p = pure(:bd) |>
            Ressac.n(2)     |> Ressac.n(5)     |>
            Ressac.room(0.1) |> Ressac.room(0.8) |>
            Ressac.delay(0.2) |> Ressac.delay(0.1) |>
            Ressac.shape(0.5) |> Ressac.shape(0.9)
        v = p(0//1, 1//1)[1].value
        @test v[:n]     == 5
        @test v[:room]  == 0.8
        @test v[:delay] == 0.1
        @test v[:shape] == 0.9
    end

    @testset "overwrite helpers accept pattern values too" begin
        np = Pattern{Int}((s, e) -> [Event{Int}(0//1, 1//1, 7)])
        p = pure(:bd) |> Ressac.n(np)
        @test p(0//1, 1//1)[1].value[:n] == 7
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`
Expected: FAIL.

- [ ] **Step 3: Implement**

Append to `src/controls.jl`:

```julia
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
pan(0.5) |> pan(0.3) to mean pan = 0.15).
"""
pan(x)   = _control_op(:pan,   _overwrite, x)
n(x)     = _control_op(:n,     _overwrite, x)
room(x)  = _control_op(:room,  _overwrite, x)
delay(x) = _control_op(:delay, _overwrite, x)
shape(x) = _control_op(:shape, _overwrite, x)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: PASS (473+ tests).

- [ ] **Step 5: Commit**

```bash
git add src/controls.jl test/test_controls.jl
git commit -m "$(cat <<'EOF'
controls: pan/n/room/delay/shape (overwrite helpers)

Five last-write-wins helpers for params that don't compose musically:
pan(0.5) |> pan(0.3) means "pan = 0.3", not 0.15. Same _control_op
backend as the compositional helpers — just with an _overwrite binary
op.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: `event_to_osc(Event{ControlMap})` — no-preset path

**Files:**
- Modify: `src/scheduler.jl`
- Modify: `src/plugin_handlers.jl`
- Modify: `test/test_scheduler.jl`

- [ ] **Step 1: Write the failing test**

Append to `test/test_scheduler.jl` inside the existing `@testset "scheduler"`, right after the existing `event_to_osc` testsets:

```julia
    @testset "event_to_osc(Event{ControlMap}) no instrument — :s first, alpha rest" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        cm = Dict{Symbol,Any}(:s => :bd, :gain => 0.8, :lpf => 200)
        msg = Ressac.event_to_osc(Event(0//1, 1//1, cm))
        @test msg.address == "/dirt/play"
        # :s first, then :gain and :lpf alphabetically
        @test msg.args == Any["s", "bd", "gain", Float32(0.8), "lpf", Int32(200)]
    end

    @testset "event_to_osc(Event{ControlMap}) :s = Symbol becomes String" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        cm = Dict{Symbol,Any}(:s => :sn)
        msg = Ressac.event_to_osc(Event(0//1, 1//1, cm))
        @test msg.args == Any["s", "sn"]
    end

    @testset "event_to_osc(Event{ControlMap}) drops unsupported value types" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        cm = Dict{Symbol,Any}(:s => :bd, :junk => Dict("x" => 1))
        msg = @test_logs (:warn, r"unsupported OSC value") match_mode=:any begin
            Ressac.event_to_osc(Event(0//1, 1//1, cm))
        end
        @test msg.args == Any["s", "bd"]   # :junk dropped
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`
Expected: FAIL with "No event_to_osc method for Event{Dict{Symbol, Any}}" (the catch-all error from existing fallback).

- [ ] **Step 3: Add Symbol → String OSC conversion**

Edit `src/plugin_handlers.jl`, add immediately after the existing `_osc_value(v::AbstractString)` definition (around line 39):

```julia
_osc_value(v::Symbol) = String(v)
```

- [ ] **Step 4: Implement the ControlMap dispatch**

Edit `src/scheduler.jl`. Right after the existing `event_to_osc(::Event{Symbol})` method and before `event_to_osc(ev::Event) = throw(...)`, insert:

```julia
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
            # Preset is the base; preset's :s is the literal target.
            for (k, v) in instr.params
                final[Symbol(k)] = v
            end
        else
            # No preset → :s is a literal sample name.
            final[:s] = routing
        end
    end

    # Pipe overrides every key except :s (preset/routing already settled it).
    for (k, v) in cm
        k === :s && continue
        final[k] = v
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
```

- [ ] **Step 5: Run test to verify it passes**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: PASS (476+ tests).

- [ ] **Step 6: Commit**

```bash
git add src/scheduler.jl src/plugin_handlers.jl test/test_scheduler.jl
git commit -m "$(cat <<'EOF'
scheduler: event_to_osc(Event{ControlMap}) — no-preset path

Dispatch ControlMap-carrying events from effect chains. Args are
ordered :s first, then alphabetically; unsupported value types are
warned + dropped. Symbol values get a String conversion via the new
_osc_value(::Symbol) method in plugin_handlers.

Preset interaction comes in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: ControlMap dispatch — instrument preset + pipe override

**Files:**
- Modify: `test/test_scheduler.jl`

(Implementation already covers both paths from Task 8 — this task verifies the preset interaction with tests.)

- [ ] **Step 1: Write the failing test**

Append inside the same `@testset "scheduler"`:

```julia
    @testset "event_to_osc(Event{ControlMap}) preset seeds, pipe overrides" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        try
            Ressac.register_instrument!(Ressac.InstrumentEntry(
                :kicklourd, "t",
                Pair{String,Any}["s" => "bd", "n" => 3, "gain" => 1.2, "lpf" => 200],
                Dict{String,Any}(),
            ))
            cm = Dict{Symbol,Any}(:s => :kicklourd, :gain => 0.96)
            msg = Ressac.event_to_osc(Event(0//1, 1//1, cm))
            # Preset's :s ("bd") wins; pipe's :gain (0.96) overrides preset's 1.2;
            # preset's :n and :lpf preserved.
            @test msg.args == Any["s", "bd",
                                  "gain", Float32(0.96),
                                  "lpf",  Int32(200),
                                  "n",    Int32(3)]
        finally
            empty!(Ressac._INSTRUMENT_REGISTRY)
        end
    end

    @testset "event_to_osc(Event{ControlMap}) preset + pipe-only key" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        try
            Ressac.register_instrument!(Ressac.InstrumentEntry(
                :bassy, "t",
                Pair{String,Any}["s" => "bassline", "gain" => 0.8],
                Dict{String,Any}(),
            ))
            cm = Dict{Symbol,Any}(:s => :bassy, :room => 0.5)
            msg = Ressac.event_to_osc(Event(0//1, 1//1, cm))
            # :s from preset, :gain from preset, :room only from pipe.
            @test msg.args == Any["s", "bassline",
                                  "gain", Float32(0.8),
                                  "room", Float32(0.5)]
        finally
            empty!(Ressac._INSTRUMENT_REGISTRY)
        end
    end

    @testset "event_to_osc(Event{ControlMap}) preset present but pipe :s redirects" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        try
            Ressac.register_instrument!(Ressac.InstrumentEntry(
                :kicklourd, "t",
                Pair{String,Any}["s" => "bd", "gain" => 1.2],
                Dict{String,Any}(),
            ))
            # User explicitly redirected :s to a non-instrument symbol.
            cm = Dict{Symbol,Any}(:s => :sn, :gain => 0.5)
            msg = Ressac.event_to_osc(Event(0//1, 1//1, cm))
            # :s = "sn" (no preset matched), :gain from pipe.
            @test msg.args == Any["s", "sn", "gain", Float32(0.5)]
        finally
            empty!(Ressac._INSTRUMENT_REGISTRY)
        end
    end

    @testset "event_to_osc(Event{ControlMap}) end-to-end via gain helper" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        try
            Ressac.register_instrument!(Ressac.InstrumentEntry(
                :kicklourd, "t",
                Pair{String,Any}["s" => "bd", "gain" => 1.2, "lpf" => 200],
                Dict{String,Any}(),
            ))
            p = pure(:kicklourd) |> Ressac.gain(0.8) |> Ressac.gain(1.2)
            ev = p(0//1, 1//1)[1]
            msg = Ressac.event_to_osc(ev)
            @test msg.args[1] == "s"
            @test msg.args[2] == "bd"
            # Pipe composed: 0.8 × 1.2 = 0.96 ; preset's 1.2 dropped.
            gain_idx = findfirst(==("gain"), msg.args)
            @test gain_idx !== nothing
            @test msg.args[gain_idx + 1] ≈ Float32(0.96)
            # preset's :lpf survives because pipe didn't touch it.
            lpf_idx = findfirst(==("lpf"), msg.args)
            @test lpf_idx !== nothing
            @test msg.args[lpf_idx + 1] == Int32(200)
        finally
            empty!(Ressac._INSTRUMENT_REGISTRY)
        end
    end
```

- [ ] **Step 2: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: PASS (480+ tests). All preset interaction tests pass against the Task 8 implementation.

- [ ] **Step 3: Commit**

```bash
git add test/test_scheduler.jl
git commit -m "$(cat <<'EOF'
scheduler: tests — ControlMap dispatch with instrument preset

Verifies the preset/pipe interaction:
- preset seeds the dict (its :s is the literal sample to play)
- pipe overrides every key it touches (pipe-wins-entirely)
- pipe-only keys (e.g. :room) join preset-only keys
- redirecting :s away from the instrument falls through to literal
- end-to-end via the gain helper composes through to the right args

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Exports + precompile workload

**Files:**
- Modify: `src/Ressac.jl`

- [ ] **Step 1: Add exports**

Edit `src/Ressac.jl`, find the existing export block (around line 31-40), and append after the `register_synth!` export line:

```julia
export ControlMap, ControlPattern, set, gain, lpf, hpf, speed
export pan, n, room, delay, shape
```

- [ ] **Step 2: Extend the precompile workload**

Edit `src/Ressac.jl`, find the `@compile_workload begin` block. After the existing block that registers `:_pc_kick` instrument and exercises `event_to_osc`, append (still inside `@compile_workload`):

```julia
    # Effect chain hot paths: lift, set, gain (compose ×), lpf (compose min),
    # overwrite helper, dispatch with and without preset.
    try
        ctrl_p = pure(:bd) |> gain(0.8) |> gain(1.2) |> lpf(2000) |> pan(0.3)
        ctrl_evs = ctrl_p(0//1, 1//1)
        if !isempty(ctrl_evs)
            event_to_osc(ctrl_evs[1])
        end

        # Pattern-valued helper path.
        gp = Pattern{Float64}((s, e) -> [Event{Float64}(0//1, 1//1, 0.7)])
        pat_p = pure(:bd) |> gain(gp)
        pat_evs = pat_p(0//1, 1//1)
        if !isempty(pat_evs)
            event_to_osc(pat_evs[1])
        end

        # Dispatch with preset hit.
        empty!(_INSTRUMENT_REGISTRY)
        register_instrument!(InstrumentEntry(:_pc_pre, "pc",
            Pair{String,Any}["s" => "bd", "gain" => 1.2],
            Dict{String,Any}()))
        preset_evs = (pure(:_pc_pre) |> gain(0.5))(0//1, 1//1)
        if !isempty(preset_evs)
            event_to_osc(preset_evs[1])
        end
        empty!(_INSTRUMENT_REGISTRY)
    catch
        empty!(_INSTRUMENT_REGISTRY)
    end
```

- [ ] **Step 3: Run the full test suite to confirm precompile doesn't break anything**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: PASS (480+ tests). Watch for any precompile-time warnings.

- [ ] **Step 4: Commit**

```bash
git add src/Ressac.jl
git commit -m "$(cat <<'EOF'
Ressac: export effect API + precompile new paths

ControlMap, ControlPattern, set, and the 9 named helpers are now public.
Precompile workload exercises the lift path, scalar + pattern-valued
gain, an overwrite helper, and event_to_osc with/without instrument
preset — so first live use of the effect chain is hot.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Cheatsheet — Effects & overrides section with gotchas

**Files:**
- Modify: `docs/cheatsheet.md`

- [ ] **Step 1: Add the new section**

Edit `docs/cheatsheet.md`. Find the line containing `## Instruments & synths` and the next section heading after it. Insert the new section right before the next `##` heading (typically `## Common gotchas`):

```markdown
## Effects & overrides

Chain OSC params onto a pattern with the pipe form. Helpers accept either
a scalar or another `Pattern`:

```julia
@d1 p"bd hh sn hh" |> gain(0.8) |> lpf(2000)
@d2 p"bd*4"        |> gain(p"1 0.7 0.5 1")  # gain varies over the cycle
@d3 p"kicklourd"   |> room(0.4) |> delay(0.2)
```

### Helper table

| Helper | Compose op | Identity-ish |
|---|---|---|
| `gain(x)`   | × (multiplicative) | 1.0 |
| `speed(x)`  | × | 1.0 |
| `lpf(x)`    | `min` (the more restrictive cutoff wins) | +∞ |
| `hpf(x)`    | `max` | 0 |
| `pan(x)`    | overwrite (last write wins) | — |
| `n(x)`      | overwrite | — |
| `room(x)`   | overwrite | — |
| `delay(x)`  | overwrite | — |
| `shape(x)`  | overwrite | — |
| `set(:k, v)`| overwrite (escape hatch for any OSC key) | — |

### Composition rules (read carefully)

- **Within the pipe**, each helper composes with whatever the previous
  helper put in the event. `gain(0.8) |> gain(1.2)` is `gain ≈ 0.96`;
  `lpf(2000) |> lpf(500)` is `lpf = 500`.
- **Preset vs pipe**: an instrument preset's value is a **default**.
  If the pipe touches a key, the **pipe wins entirely** for that key,
  even if the pipe value would naively "compose" with the preset.

### Gotchas

- **`gain(1.0)` is not a no-op when there's an instrument preset.** If
  `kicklourd` declares `gain=1.2`, then `kicklourd |> gain(1.0)` ships
  `gain=1.0` to OSC, not 1.2. The pipe touched `:gain`, the preset's
  value got dropped. To inspect what an instrument actually declares:
  ```
  :instruments kicklourd
  ```
- **`set(:gain, 0.5) |> gain(2.0)` is `gain = 1.0`.** `set` writes 0.5
  unconditionally; `gain(2.0)` then sees `:gain=0.5` already there and
  composes × → 1.0. Mixing `set` and named helpers on the same key
  works, but it's worth being explicit in your head about which
  operator wins where.
- **`pan(0.5) |> pan(0.3)` is `pan = 0.3`, not 0.15.** Pan is overwrite
  by design — averaging two pans gives a meaningless result.
- **First-write is not composed.** The very first `gain(x)` in a chain
  (with no preset providing a `:gain` already) is a plain set: it does
  not multiply against an implicit 1.0. This matters if you split a
  chain over multiple lines: `@d1 p"bd" |> gain(0.5)` and later
  `unset!(:d1)` then `@d1 p"bd" |> gain(0.5) |> gain(0.5)` will give
  you `gain=0.25`, not `gain=0.5*0.5*0.5=0.125`.

### Escape hatch

For any OSC param Ressac doesn't sugar, use `set`:

```julia
@d1 p"bd"   |> set(:cut, 1) |> set(:orbit, 2)
@d2 p"arpy" |> set(:vowel, p"a e i o u")  # pattern-valued too
```

`set` is always overwrite.

### REPL introspection

There's no built-in "list of helpers" query — they're a fixed Julia
namespace. `gain`, `pan`, `n`, `speed`, `lpf`, `hpf`, `room`, `delay`,
`shape`, and `set` are all exported by the `Ressac` module. `:guide`
shows the same helper table.
```

- [ ] **Step 2: Update `:guide` to mention effects**

Edit `src/tui_bindings.jl`. Find the `_GUIDE_LINES` const and insert two lines into the existing vector — right after the `"  e             — eval block under cursor (prefix N → defer to slot dN)"` line, add:

```julia
    "Effect chain (pipe):",
    "  gain / speed / lpf / hpf / pan / n / room / delay / shape / set",
    "  gain × | lpf min | hpf max | speed × | rest overwrite",
    "  preset values drop entirely on any pipe key — gain(1.0) is not a no-op",
```

- [ ] **Step 3: Verify and commit**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: PASS (480+ tests, no regressions).

```bash
git add docs/cheatsheet.md src/tui_bindings.jl
git commit -m "$(cat <<'EOF'
docs(cheatsheet): Effects & overrides section + gotchas

Helper table with composition ops, explicit composition rules, and the
four notable gotchas (gain(1.0) drops preset, set+helper mix, pan
overwrite by design, first-write is not composed). Updated :guide
in-app cheatsheet to mention the effect helpers and the preset-drop
rule.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-review summary

**Spec coverage:**
- `ControlMap = Dict{Symbol,Any}` — Task 1
- `ControlPattern = Pattern{ControlMap}` — Task 1
- `_lift_to_control` + idempotency — Task 2
- `_symbol_to_control_map` (`bd:1` → `:s + :n`) — Task 1
- `set(:k, scalar)` and `set(:k, ::Pattern)` — Tasks 3, 4
- `_control_op` backend — Task 5
- `gain` (× compose) — Task 5
- `lpf` (min), `hpf` (max), `speed` (×) — Task 6
- `pan`, `n`, `room`, `delay`, `shape` (overwrite) — Task 7
- `event_to_osc(Event{ControlMap})` — Tasks 8, 9 (no-preset, with-preset)
- `_osc_value(::Symbol)` — Task 8
- :s routing semantics (pipe :s drives lookup, never overrides preset's literal) — Tasks 8, 9
- Args order: `:s` first, alpha rest — Task 8
- Exports + precompile — Task 10
- Cheatsheet "Effects & overrides" with gotchas — Task 11
- `:guide` in-app update — Task 11

**Out-of-scope (deferred):**
- Mini-notation `#` syntax — spec'd out of scope
- `cut`, `orbit`, `begin`, `end`, `crush`, etc. — accessible via `set`
- TUI effect autocomplete — sub-project 6

**Placeholder scan:** none.

**Type consistency:** `ControlMap`, `ControlPattern`, `set`, `_control_op`, helper names all match between tasks. `_overwrite` defined once in Task 7 used implicitly by helpers there.
