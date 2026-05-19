# Multi-line TUI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the M4 v1 TUI with a vim-style modal multi-line editor backed by a deferred-eval scheduler, per spec `docs/journal/20260519_multiline_tui_design.md`.

**Architecture:** Build the live API foundation (`@dN` macros, scheduler `pending` queue, `_EVAL_MODE` flag, `last_fired_at`) without touching the v1 TUI. Then split the TUI into focused files (`tui_model`, `tui_buffer`, `tui_eval`, `tui_search`, `tui_bindings`, `tui_view`) and replace v1 piece by piece while keeping every commit green. Curried combinator forms unlock the `|>` pipe-style. Single-threaded tests via `Core.eval(Main, ...)` + `MockOSCClient` for the full TUI code path.

**Tech Stack:** Julia 1.10+, `TerminalUserInterfaces.jl` v0.8 (already in deps), Test stdlib, `PrecompileTools` (already in deps).

---

## File structure

| File | Status | Responsibility |
|---|---|---|
| `src/combinators.jl` | extend | Add curried single-arg methods for `fast`, `slow`, `every`, `mask`, `stack`. |
| `src/scheduler.jl` | extend | Add `pending::Dict`, `last_fired_at::Dict`; new `schedule_pattern!`; drain in `_step!`; record per-slot fire times. |
| `src/live_api.jl` | **new** | `_EVAL_MODE` ref, `_route_to_slot!`, generated `@d1`..`@d64` macros. |
| `src/tui_model.jl` | **new** | `LiveModel` struct with buffer + cursor + mode + chord state. |
| `src/tui_buffer.jl` | **new** | Pure buffer mutations: insert char, delete, split line, join, paragraph bounds. |
| `src/tui_eval.jl` | **new** | Block extraction at cursor + eval routing through `_EVAL_MODE`. |
| `src/tui_search.jl` | **new** | `last_search` regex, `n`/`N` cycling, `gd<digits>` chord resolution. |
| `src/tui_bindings.jl` | **new** | `TUI.update!` dispatch by mode (insert / normal / visual / command). |
| `src/tui_view.jl` | **new** | `TUI.view`: buffer renderer, active markers, top-line activity widget, command prompt. |
| `src/tui.jl` | **rewrite** | Slim entry-point: includes the six tui_*.jl files; defines `start_live!`/`stop_live!`/`live()`. |
| `src/Ressac.jl` | extend | Include new files; export new macros + functions. |
| `test/test_combinators.jl` | extend | Curried-form tests. |
| `test/test_scheduler.jl` | extend | `pending` queue, `schedule_pattern!`, `last_fired_at` tests. |
| `test/test_live_api.jl` | **new** | Macro expansion, `_EVAL_MODE` dispatch, slot range validation. |
| `test/test_tui_buffer.jl` | **new** | Pure buffer-mutation tests. |
| `test/test_tui.jl` | **rewrite** | End-to-end tests for modes, eval, mute, goto, search, visual, yank, view. |
| `test/runtests.jl` | extend | Include the new test files. |

`scripts/live.jl` is unchanged. Old v1 TUI tests are deleted with the v1 file.

---

## Phase A — Live API foundation

These tasks add API surface without touching the v1 TUI; existing tests stay green throughout. Each curried combinator is its own task to keep diffs small.

### Task A1: Curried `fast(n)`

**Files:**
- Modify: `src/combinators.jl`
- Test: `test/test_combinators.jl`

- [ ] **Step 1: Write the failing test**

Append to `test/test_combinators.jl` inside the `combinators` testset:

```julia
    @testset "curried fast(n) is fast(n, _)" begin
        # The single-arg form should return a function that, applied to a
        # Pattern, gives the same result as the two-arg form.
        curried = fast(2)
        @test curried isa Function
        @test query(curried(pure(:bd)), 0, 1) == query(fast(2, pure(:bd)), 0, 1)
        # Pipe usage matches.
        @test query(pure(:bd) |> fast(2), 0, 1) == query(fast(2, pure(:bd)), 0, 1)
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: error "MethodError: no method matching fast(::Int64)" inside the new testset.

- [ ] **Step 3: Write minimal implementation**

Append to `src/combinators.jl` after the existing `fast(n, p)` definition:

```julia
"""
    fast(n::Real) -> (Pattern -> Pattern)

Curried form: `fast(n)(p) == fast(n, p)`. Lets `p |> fast(n)` thread the
pattern as the right-hand arg under Julia's native `|>`.
"""
fast(n::Real) = p::Pattern -> fast(n, p)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all tests pass, count increased by 1 testset.

- [ ] **Step 5: Commit**

```bash
git add src/combinators.jl test/test_combinators.jl
git commit -m "combinators: curried fast(n) for pipe-style"
```

### Task A2: Curried `slow(n)`

**Files:**
- Modify: `src/combinators.jl`
- Test: `test/test_combinators.jl`

- [ ] **Step 1: Write the failing test**

Append to `test/test_combinators.jl` inside the `combinators` testset:

```julia
    @testset "curried slow(n) is slow(n, _)" begin
        curried = slow(2)
        @test curried isa Function
        @test query(pure(:bd) |> slow(2), 0, 2) == query(slow(2, pure(:bd)), 0, 2)
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: MethodError on `slow(::Int)`.

- [ ] **Step 3: Write minimal implementation**

Append to `src/combinators.jl` after `slow(n, p)`:

```julia
"""
    slow(n::Real) -> (Pattern -> Pattern)

Curried form: `slow(n)(p) == slow(n, p)`.
"""
slow(n::Real) = p::Pattern -> slow(n, p)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/combinators.jl test/test_combinators.jl
git commit -m "combinators: curried slow(n)"
```

### Task A3: Curried `every(n, f)`

**Files:**
- Modify: `src/combinators.jl`
- Test: `test/test_combinators.jl`

- [ ] **Step 1: Write the failing test**

Append to `test/test_combinators.jl` inside `combinators`:

```julia
    @testset "curried every(n, f) is every(n, f, _)" begin
        curried = every(2, rev)
        @test curried isa Function
        @test query(pure(:bd) |> every(2, rev), 0, 2) ==
              query(every(2, rev, pure(:bd)), 0, 2)
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: MethodError on `every(::Int, ::typeof(rev))`.

- [ ] **Step 3: Write minimal implementation**

Append to `src/combinators.jl` after `every(n, f, p)`:

```julia
"""
    every(n::Int, f) -> (Pattern -> Pattern)

Curried form: `every(n, f)(p) == every(n, f, p)`.
"""
every(n::Int, f) = p::Pattern -> every(n, f, p)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/combinators.jl test/test_combinators.jl
git commit -m "combinators: curried every(n, f)"
```

### Task A4: Curried `mask(q)` and `stack(q)`

**Files:**
- Modify: `src/algebra.jl` (where `mask` lives), `src/combinators.jl` (where `stack` lives)
- Test: `test/test_algebra.jl`, `test/test_combinators.jl`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_algebra.jl` inside the `algebra` testset:

```julia
    @testset "curried mask(q) is mask(_, q)" begin
        mask_pat = Pattern{Bool}((s::Rational, e::Rational) ->
            [Event{Bool}(s, e, true)])
        @test query(pure(1) |> mask(mask_pat), 0, 1) ==
              query(mask(pure(1), mask_pat), 0, 1)
    end
```

Append to `test/test_combinators.jl` inside `combinators`:

```julia
    @testset "curried stack(q) is stack(_, q)" begin
        @test query(pure(:bd) |> stack(pure(:sn)), 0, 1) ==
              query(stack(pure(:bd), pure(:sn)), 0, 1)
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: two MethodErrors, one for `mask(::Pattern{Bool})` and one for `stack(::Pattern{Symbol})` (single-arg form).

- [ ] **Step 3: Write minimal implementations**

Append to `src/algebra.jl` after the existing `mask` function:

```julia
"""
    mask(q::Pattern{Bool}) -> (Pattern{T} -> Pattern{T})

Curried form: `mask(q)(p) == mask(p, q)`.
"""
mask(q::Pattern{Bool}) = p::Pattern -> mask(p, q)
```

Append to `src/combinators.jl` after the existing `stack` function:

```julia
"""
    stack(q::Pattern{T}) -> (Pattern{T} -> Pattern{T})

Curried form: `stack(q)(p) == stack(p, q)`. Note: existing
`stack(ps::Vararg{Pattern{T}})` already covers `stack(p, q, r, …)`, so
this single-arg version disambiguates as "curry on the lone arg".
"""
stack(q::Pattern{T}) where {T} = p::Pattern{T} -> stack(p, q)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/algebra.jl src/combinators.jl test/test_algebra.jl test/test_combinators.jl
git commit -m "combinators/algebra: curried mask(q) and stack(q)"
```

### Task A5: Scheduler `pending` queue + `schedule_pattern!`

**Files:**
- Modify: `src/scheduler.jl`
- Test: `test/test_scheduler.jl`

- [ ] **Step 1: Write the failing test**

Append to `test/test_scheduler.jl` inside the `scheduler` testset:

```julia
    @testset "schedule_pattern! queues, _step! installs at apply_at" begin
        mock = MockOSCClient()
        s = Scheduler(mock; cps=1.0, lookahead=0.05)
        s.t_start = 0.0
        # Schedule a pattern to apply at cycle 2.
        schedule_pattern!(s, :d1, pure(:bd), 2 // 1)
        @test haskey(s.pending, :d1)
        @test !haskey(s.patterns, :d1)
        # Step at now=0.0 (window [0, 0.05)): pending stays.
        Ressac._step!(s, 0.0)
        @test haskey(s.pending, :d1)
        @test !haskey(s.patterns, :d1)
        # Step at now=2.0 (window [≈last, 2.05)): drain.
        Ressac._step!(s, 2.0)
        @test !haskey(s.pending, :d1)
        @test haskey(s.patterns, :d1)
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: `UndefVarError: pending` (struct field doesn't exist) and `UndefVarError: schedule_pattern!`.

- [ ] **Step 3: Write minimal implementation**

In `src/scheduler.jl`, replace the `mutable struct Scheduler{C}` block with:

```julia
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
    )
end
```

Add immediately after the constructor:

```julia
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
```

Then modify `_step!` to drain `pending` at the start of the locked block. Replace the existing `_step!` body so the locked block reads:

```julia
function _step!(s::Scheduler, now::Float64)
    lock(s.lock) do
        end_cycles = (now + s.lookahead) * s.cps
        # Drain any pending pattern swaps whose apply_at_cycle has arrived.
        for (slot, (p, at)) in pairs(s.pending)
            if Float64(at) <= end_cycles
                s.patterns[slot] = p
                delete!(s.pending, slot)
            end
        end
        start_cycles = s.last_end_cycles
        end_cycles > start_cycles || return
        n_start = floor(Int, start_cycles)
        n_stop  = ceil(Int, end_cycles)
        for (slot, pattern) in s.patterns
            for n in n_start:(n_stop - 1)
                events = pattern(Rational{Int64}(n), Rational{Int64}(n + 1))
                for ev in events
                    ev_start = Float64(ev.start)
                    if start_cycles <= ev_start < end_cycles
                        fire_time = s.t_start + ev_start / s.cps
                        bundle = OSCBundle(fire_time, [event_to_osc(ev)])
                        send_osc(s.osc, encode(bundle))
                    end
                end
            end
        end
        s.last_end_cycles = end_cycles
    end
end
```

Note: the existing `_step!` is replaced wholesale because (a) we now iterate `(slot, pattern)` instead of `values(...)` to allow per-slot `last_fired_at` updates in the next task, and (b) the drain block is new.

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass, including the new test plus the regression test from previous commits.

- [ ] **Step 5: Commit**

```bash
git add src/scheduler.jl test/test_scheduler.jl
git commit -m "scheduler: pending queue + schedule_pattern! for deferred swaps"
```

### Task A6: `last_fired_at` per-slot tracking

**Files:**
- Modify: `src/scheduler.jl`
- Test: `test/test_scheduler.jl`

- [ ] **Step 1: Write the failing test**

Append to `test/test_scheduler.jl` inside `scheduler`:

```julia
    @testset "last_fired_at records the most recent event per slot" begin
        mock = MockOSCClient()
        s = Scheduler(mock; cps=1.0, lookahead=0.05)
        s.t_start = 0.0
        set_pattern!(s, :d1, pure(:bd))
        @test !haskey(s.last_fired_at, :d1)
        Ressac._step!(s, 0.0)
        @test haskey(s.last_fired_at, :d1)
        # The recorded time should be near (but past) t_start because the
        # event fires at the start of cycle 0.
        @test s.last_fired_at[:d1] ≈ s.t_start atol=0.1
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: `last_fired_at` stays empty because `_step!` never writes to it.

- [ ] **Step 3: Write minimal implementation**

In `src/scheduler.jl`, inside the `_step!` event-shipping loop, after `send_osc(...)`, add a `last_fired_at` update. Replace the inner `for ev in events` loop with:

```julia
                for ev in events
                    ev_start = Float64(ev.start)
                    if start_cycles <= ev_start < end_cycles
                        fire_time = s.t_start + ev_start / s.cps
                        bundle = OSCBundle(fire_time, [event_to_osc(ev)])
                        send_osc(s.osc, encode(bundle))
                        s.last_fired_at[slot] = time()
                    end
                end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/scheduler.jl test/test_scheduler.jl
git commit -m "scheduler: record last_fired_at per slot for activity widget"
```

### Task A7: Export new scheduler functions

**Files:**
- Modify: `src/Ressac.jl`

- [ ] **Step 1: Write the failing test (manual REPL test)**

(No test file change; we'll verify the export by ensuring `using Ressac; schedule_pattern!` resolves in the precompile workload which is exercised below.)

- [ ] **Step 2: Run tests to see baseline**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass (no regressions).

- [ ] **Step 3: Add the export**

In `src/Ressac.jl`, replace the existing `export Scheduler, ...` line with:

```julia
export Scheduler, start!, stop!, set_pattern!, unset_pattern!, schedule_pattern!, set_cps!, hush!
```

- [ ] **Step 4: Verify import works**

Run: `julia --project=. -e 'using Ressac; @assert isdefined(Main, :schedule_pattern!); println("ok")'`
Expected: prints `ok`.

- [ ] **Step 5: Commit**

```bash
git add src/Ressac.jl
git commit -m "Ressac: export schedule_pattern!"
```

### Task A8: Create `src/live_api.jl` with `_EVAL_MODE` + `_route_to_slot!`

**Files:**
- Create: `src/live_api.jl`
- Create: `test/test_live_api.jl`
- Modify: `src/Ressac.jl`, `test/runtests.jl`

- [ ] **Step 1: Write the failing test**

Create `test/test_live_api.jl`:

```julia
using Test
using Ressac

@testset "live_api" begin
    @testset "_route_to_slot! immediate mode delegates to set_pattern!" begin
        mock = MockOSCClient()  # from test_scheduler.jl
        sched = Scheduler(mock; cps=1.0)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            Ressac._EVAL_MODE[] = (:immediate, 0)
            Ressac._route_to_slot!(:d1, pure(:bd))
            @test haskey(sched.patterns, :d1)
            @test !haskey(sched.pending, :d1)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            Ressac._EVAL_MODE[] = (:immediate, 0)
        end
    end

    @testset "_route_to_slot! deferred mode delegates to schedule_pattern!" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=1.0)
        sched.t_start = time()  # so _current_cycle returns ~0
        Ressac._LIVE_SCHEDULER[] = sched
        try
            Ressac._EVAL_MODE[] = (:deferred, 2)
            Ressac._route_to_slot!(:d1, pure(:bd))
            @test !haskey(sched.patterns, :d1)
            @test haskey(sched.pending, :d1)
            (_, at) = sched.pending[:d1]
            # current cycle ≈ 0, so target = ceil(0) + 2 = 2.
            @test at == 2 // 1
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            Ressac._EVAL_MODE[] = (:immediate, 0)
        end
    end

    @testset "_route_to_slot! with no body unsets the slot" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=1.0)
        set_pattern!(sched, :d1, pure(:bd))
        Ressac._LIVE_SCHEDULER[] = sched
        try
            Ressac._route_to_slot!(:d1)
            @test !haskey(sched.patterns, :d1)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end
end
```

Add to `test/runtests.jl` at the end of the testset, before the closing `end`:

```julia
    include("test_live_api.jl")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: `UndefVarError: _EVAL_MODE`, `UndefVarError: _route_to_slot!`.

- [ ] **Step 3: Create `src/live_api.jl`**

```julia
# Live-coding entry points used by the TUI. All routes go through
# `_route_to_slot!` which inspects `_EVAL_MODE` to choose between immediate
# `set_pattern!` and deferred `schedule_pattern!`. The TUI sets the mode
# before `Core.eval(Main, …)` and restores it in a `finally`.

const _EVAL_MODE = Ref{Tuple{Symbol,Int}}((:immediate, 0))

_current_cycle(s::Scheduler) = (time() - s.t_start) * s.cps

"""
    _route_to_slot!(slot::Symbol, p::Pattern)

Install `p` at `slot` either immediately or at +N cycles, depending on
`_EVAL_MODE[]`. Called by the `@d1`..`@d64` macros.
"""
function _route_to_slot!(slot::Symbol, p::Pattern)
    sched = _check_live()
    mode, n = _EVAL_MODE[]
    if mode === :immediate
        set_pattern!(sched, slot, p)
    else
        target = Rational{Int64}(ceil(Int, _current_cycle(sched)) + n)
        schedule_pattern!(sched, slot, p, target)
    end
    return nothing
end

"""
    _route_to_slot!(slot::Symbol)

No-body form: unset the slot. Always immediate (musical "cut" doesn't
need to wait for a cycle boundary).
"""
function _route_to_slot!(slot::Symbol)
    unset_pattern!(_check_live(), slot)
    return nothing
end
```

In `src/Ressac.jl`, add `include("live_api.jl")` *after* `include("tui.jl")` (so it can see `_check_live`):

```julia
include("core.jl")
include("combinators.jl")
include("algebra.jl")
include("mininotation.jl")
include("osc.jl")
include("scheduler.jl")
include("tui.jl")
include("live_api.jl")  # NEW — after tui.jl for _check_live
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/live_api.jl src/Ressac.jl test/test_live_api.jl test/runtests.jl
git commit -m "live_api: _EVAL_MODE flag + _route_to_slot! dispatcher"
```

### Task A9: Generate `@d1`..`@d64` macros

**Files:**
- Modify: `src/live_api.jl`
- Modify: `src/Ressac.jl`
- Modify: `test/test_live_api.jl`

- [ ] **Step 1: Write the failing test**

Append to `test/test_live_api.jl` inside the `live_api` testset:

```julia
    @testset "@d1 macro expands to _route_to_slot!(:d1, body)" begin
        # macroexpand returns the unescaped expression.
        ex = @macroexpand @d1 pure(:bd)
        # Look for a call to _route_to_slot! with :d1 as the first arg.
        @test ex isa Expr && ex.head === :call
        @test ex.args[1] === :(Ressac._route_to_slot!) || ex.args[1] === :_route_to_slot!
        @test ex.args[2] === :(:d1) || ex.args[2] === QuoteNode(:d1)
    end

    @testset "@d3 with no body unsets the slot" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=1.0)
        set_pattern!(sched, :d3, pure(:bd))
        Ressac._LIVE_SCHEDULER[] = sched
        try
            Core.eval(Main, :(@d3))
            @test !haskey(sched.patterns, :d3)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "@d64 is the highest slot" begin
        @test isdefined(Ressac, Symbol("@d64"))
        @test !isdefined(Ressac, Symbol("@d65"))
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: `LoadError: UndefVarError: @d1`.

- [ ] **Step 3: Add macro generation to `src/live_api.jl`**

Append:

```julia
# Generate @d1..@d64. Each expands to a `_route_to_slot!(:dN, body)` call,
# or `_route_to_slot!(:dN)` when called with no body.
for n in 1:64
    macro_name = Symbol("d", n)
    slot_sym = QuoteNode(Symbol("d", n))
    @eval begin
        macro $(macro_name)(expr)
            return Expr(:call, GlobalRef(@__MODULE__, :_route_to_slot!),
                        $slot_sym, esc(expr))
        end
        macro $(macro_name)()
            return Expr(:call, GlobalRef(@__MODULE__, :_route_to_slot!),
                        $slot_sym)
        end
    end
end
```

In `src/Ressac.jl`, extend the `export` line that ends with `cps!` to also export every macro:

```julia
export live, start_live!, stop_live!, restart_live!, d!, unset!, hush_all!, cps!

# Export every @d1..@d64 macro. Doing it here keeps the macro generator
# in live_api.jl tidy.
for n in 1:64
    @eval export $(Symbol("@d", n))
end
```

(Place the `for` loop right after the explicit `export` statements, before the `using PrecompileTools` block.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/live_api.jl src/Ressac.jl test/test_live_api.jl
git commit -m "live_api: generate @d1..@d64 slot macros"
```

### Task A10: Update precompile workload

**Files:**
- Modify: `src/Ressac.jl`

- [ ] **Step 1: Write the failing test (verification only)**

Run: `julia --project=. -e 'using Ressac; @time @d1 pure(:bd); @time @d1 pure(:sn)'`
Expected: first call ~slow (compiles `_route_to_slot!`), second call near-zero allocations. This step is a verification; no test code added.

- [ ] **Step 2: Run baseline**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass.

- [ ] **Step 3: Extend `@compile_workload`**

In `src/Ressac.jl`, replace the existing `@compile_workload begin ... end` block with:

```julia
@compile_workload begin
    # Mini-notation: cover the parser's main branches.
    p1 = parse_minino("bd hh sn hh")
    p2 = parse_minino("<bd sn cp>")
    p3 = parse_minino("bd(3,8)")
    p4 = parse_minino("bd*4")
    p5 = parse_minino("bd!2 sn")
    p6 = parse_minino("[bd hh] sn")

    # Combinator stack + new curried forms via pipe.
    layered  = pure(:cp) |> fast(2)
    looped   = p1 |> every(3, rev)
    masked   = p1 |> mask(p"1 ~ 1 ~")
    stacked  = pure(:bd) |> stack(pure(:sn))

    # Numeric algebra path.
    np1 = pure(0) + 12

    # Full scheduler hot loop incl. pending drain.
    sched = Scheduler(_PrecompileSink(); cps=0.5, lookahead=0.05)
    sched.t_start = 0.0
    set_pattern!(sched, :d1, p1)
    set_pattern!(sched, :d2, layered)
    schedule_pattern!(sched, :d3, looped, 1 // 1)
    _step!(sched, 0.0)
    _step!(sched, 1.5)
    unset_pattern!(sched, :d1)
    hush!(sched)

    # OSC encoder/decoder.
    msg = OSCMessage("/dirt/play", Any["s", "bd"])
    bytes = encode(msg)
    decode_message(bytes)
    encode(OSCBundle(0.0, [msg]))

    # Live API: exercise _route_to_slot! both modes via the public macros.
    _LIVE_SCHEDULER[] = sched
    try
        _EVAL_MODE[] = (:immediate, 0)
        _route_to_slot!(:d4, p2)
        _EVAL_MODE[] = (:deferred, 1)
        _route_to_slot!(:d5, p3)
    finally
        _LIVE_SCHEDULER[] = nothing
        _EVAL_MODE[] = (:immediate, 0)
    end
end
```

- [ ] **Step 4: Run tests to verify**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass; precompile takes a bit longer due to the bigger workload but that's a one-time cost.

- [ ] **Step 5: Commit**

```bash
git add src/Ressac.jl
git commit -m "precompile: cover curried combinators + _route_to_slot! paths"
```

---

## Phase B — Buffer + cursor + mode skeleton

The v1 TUI keeps running through this phase. We add new files; only at Task B6 does `tui.jl` get rewritten to use them.

### Task B1: Create `src/tui_model.jl`

**Files:**
- Create: `src/tui_model.jl`

- [ ] **Step 1: Write the failing test (defer until next task)**

This task only adds the struct. Tests come in B2 when there's behaviour to test.

- [ ] **Step 2: Baseline**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass.

- [ ] **Step 3: Create `src/tui_model.jl`**

```julia
using TerminalUserInterfaces
const TUI = TerminalUserInterfaces

"""
    LiveModel

Backing model for the multi-line TUI. See
`docs/journal/20260519_multiline_tui_design.md` §4.1.
"""
@kwdef mutable struct LiveModel <: TUI.Model
    scheduler::Scheduler
    buffer::Vector{String}        = [""]
    cursor_row::Int               = 1
    cursor_col::Int               = 1
    mode::Symbol                  = :insert   # :insert | :normal | :visual_line | :command
    count_prefix::Int             = 0
    pending_chord::Symbol         = :none     # :g | :gd | :d | :y
    chord_digits::String          = ""
    last_eval_block::Dict{Symbol,NTuple{2,Int}} = Dict{Symbol,NTuple{2,Int}}()
    last_search::Union{Nothing,Regex}            = nothing
    last_search_dir::Symbol       = :forward
    yank::Vector{String}          = String[]
    visual_anchor::Union{Nothing,NTuple{2,Int}}   = nothing
    command_prefix::Char          = ' '
    command_buffer::String        = ""
    logs::Vector{String}          = String[]
    quit::Bool                    = false
end

const _MAX_LOGS = 200

function _push_log!(m::LiveModel, line::AbstractString)
    push!(m.logs, String(line))
    length(m.logs) > _MAX_LOGS && popfirst!(m.logs)
end
```

The file isn't `include`d yet — that happens in Task B6.

- [ ] **Step 4: Sanity-load**

Run: `julia --project=. -e 'include("src/tui_model.jl")' 2>&1 | tail -3`
Expected: warning about `TUI.Model` being undefined or similar (because Scheduler is not in scope when loaded standalone). This is OK; the include order in Task B6 will fix it. We're just checking the file parses.

A cleaner check: `julia --project=. -e 'using Ressac; Meta.parse(read("src/tui_model.jl", String))' 2>&1 | tail -3`
Expected: no parse error.

- [ ] **Step 5: Commit**

```bash
git add src/tui_model.jl
git commit -m "tui_model: new LiveModel struct for the v2 multi-line TUI"
```

### Task B2: Create `src/tui_buffer.jl` with insertion helpers

**Files:**
- Create: `src/tui_buffer.jl`
- Create: `test/test_tui_buffer.jl`
- Modify: `test/runtests.jl`

- [ ] **Step 1: Write the failing tests**

Create `test/test_tui_buffer.jl`:

```julia
using Test
using Ressac

@testset "tui_buffer" begin
    @testset "_insert_char! inserts at cursor and advances col" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["abc"]
        m.cursor_row = 1
        m.cursor_col = 2  # before 'b'
        Ressac._insert_char!(m, 'X')
        @test m.buffer == ["aXbc"]
        @test m.cursor_col == 3
    end

    @testset "_insert_char! at end of line extends the line" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["abc"]
        m.cursor_row = 1
        m.cursor_col = 4  # one past end
        Ressac._insert_char!(m, 'd')
        @test m.buffer == ["abcd"]
        @test m.cursor_col == 5
    end

    @testset "_split_line! creates a new row at the cursor" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["abcdef"]
        m.cursor_row = 1
        m.cursor_col = 4
        Ressac._split_line!(m)
        @test m.buffer == ["abc", "def"]
        @test (m.cursor_row, m.cursor_col) == (2, 1)
    end

    @testset "_backspace! deletes prev char or joins lines" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["abc", "def"]
        m.cursor_row = 1
        m.cursor_col = 3
        Ressac._backspace!(m)
        @test m.buffer == ["ac", "def"]
        @test (m.cursor_row, m.cursor_col) == (1, 2)

        # Cursor at col 1 of row 2 → joins with row 1.
        m.cursor_row = 2
        m.cursor_col = 1
        Ressac._backspace!(m)
        @test m.buffer == ["acdef"]
        @test (m.cursor_row, m.cursor_col) == (1, 3)
    end

    @testset "_backspace! at (1,1) is a no-op" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["abc"]
        m.cursor_row = 1
        m.cursor_col = 1
        Ressac._backspace!(m)
        @test m.buffer == ["abc"]
        @test (m.cursor_row, m.cursor_col) == (1, 1)
    end

    @testset "_delete_line! removes the current row" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["a", "b", "c"]
        m.cursor_row = 2
        m.cursor_col = 1
        deleted = Ressac._delete_line!(m)
        @test deleted == "b"
        @test m.buffer == ["a", "c"]
        @test m.cursor_row == 2  # stays, points to former "c"

        # Deleting the only line yields an empty buffer (one empty row).
        m.buffer = ["solo"]
        m.cursor_row = 1
        deleted = Ressac._delete_line!(m)
        @test deleted == "solo"
        @test m.buffer == [""]
        @test m.cursor_row == 1
    end

    @testset "_paragraph_bounds finds non-blank line ranges" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["a", "b", "", "c", "d", "e", "", "f"]
        # Cursor in para 1 (rows 1-2).
        m.cursor_row = 1
        @test Ressac._paragraph_bounds(m) == (1, 2)
        m.cursor_row = 2
        @test Ressac._paragraph_bounds(m) == (1, 2)
        # Cursor in para 2 (rows 4-6).
        m.cursor_row = 5
        @test Ressac._paragraph_bounds(m) == (4, 6)
        # Cursor on a blank row → empty range (start > stop).
        m.cursor_row = 3
        @test Ressac._paragraph_bounds(m) == (3, 2)
    end
end
```

Add to `test/runtests.jl` before the closing `end`:

```julia
    include("test_tui_buffer.jl")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: errors `UndefVarError: _insert_char!` etc.

- [ ] **Step 3: Create `src/tui_buffer.jl`**

```julia
# Pure buffer-mutation helpers. No TUI calls, no scheduler calls — every
# function takes a `LiveModel` and mutates `buffer` / `cursor_row` /
# `cursor_col`. Easy to unit-test without a TTY.

function _insert_char!(m::LiveModel, c::AbstractChar)
    line = m.buffer[m.cursor_row]
    col = m.cursor_col
    if col > lastindex(line) + 1
        col = lastindex(line) + 1
    end
    new_line = if col == 1
        string(c) * line
    elseif col > lastindex(line)
        line * string(c)
    else
        line[1:prevind(line, col)] * string(c) * line[col:end]
    end
    m.buffer[m.cursor_row] = new_line
    m.cursor_col = col + 1
    return nothing
end

function _split_line!(m::LiveModel)
    line = m.buffer[m.cursor_row]
    col = m.cursor_col
    left  = col == 1 ? "" : line[1:prevind(line, col)]
    right = col > lastindex(line) ? "" : line[col:end]
    m.buffer[m.cursor_row] = left
    insert!(m.buffer, m.cursor_row + 1, right)
    m.cursor_row += 1
    m.cursor_col = 1
    return nothing
end

function _backspace!(m::LiveModel)
    if m.cursor_col > 1
        line = m.buffer[m.cursor_row]
        col = m.cursor_col
        new_line = line[1:prevind(line, col - 1)] * (col > lastindex(line) ? "" : line[col:end])
        m.buffer[m.cursor_row] = new_line
        m.cursor_col -= 1
    elseif m.cursor_row > 1
        # Join with previous line.
        prev = m.buffer[m.cursor_row - 1]
        cur  = m.buffer[m.cursor_row]
        m.buffer[m.cursor_row - 1] = prev * cur
        deleteat!(m.buffer, m.cursor_row)
        m.cursor_row -= 1
        m.cursor_col = lastindex(prev) + 1
    end
    # else: at (1, 1), no-op.
    return nothing
end

function _delete_line!(m::LiveModel)
    deleted = m.buffer[m.cursor_row]
    if length(m.buffer) == 1
        m.buffer[1] = ""
        m.cursor_col = 1
    else
        deleteat!(m.buffer, m.cursor_row)
        m.cursor_row = clamp(m.cursor_row, 1, length(m.buffer))
        m.cursor_col = 1
    end
    return deleted
end

"""
    _paragraph_bounds(m) -> (row_start, row_stop)

Range of contiguous non-blank rows around `cursor_row`. Returns
`(cursor_row, cursor_row - 1)` (empty range) if the cursor is on a
blank row.
"""
function _paragraph_bounds(m::LiveModel)
    is_blank(s) = isempty(strip(s))
    cur = m.cursor_row
    if is_blank(m.buffer[cur])
        return (cur, cur - 1)
    end
    start = cur
    while start > 1 && !is_blank(m.buffer[start - 1])
        start -= 1
    end
    stop = cur
    while stop < length(m.buffer) && !is_blank(m.buffer[stop + 1])
        stop += 1
    end
    return (start, stop)
end
```

- [ ] **Step 4: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: still failing — the new file isn't `include`d in `Ressac.jl` yet. Add to `src/Ressac.jl` immediately after `include("tui.jl")`:

```julia
include("tui_model.jl")
include("tui_buffer.jl")
```

Re-run tests. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/tui_buffer.jl src/Ressac.jl test/test_tui_buffer.jl test/runtests.jl
git commit -m "tui_buffer: pure buffer mutation helpers + tests"
```

### Task B3: Cursor navigation helpers

**Files:**
- Modify: `src/tui_buffer.jl`
- Modify: `test/test_tui_buffer.jl`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_tui_buffer.jl` inside `tui_buffer`:

```julia
    @testset "_move_cursor! clamps to buffer bounds" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["abc", "de", "fghij"]
        m.cursor_row = 1; m.cursor_col = 1
        # Down off the end clamps col to line length+1.
        Ressac._move_cursor!(m, 0, +1)
        @test (m.cursor_row, m.cursor_col) == (2, 1)
        # Right past end of "de" clamps.
        m.cursor_col = 10
        Ressac._move_cursor!(m, +1, 0)
        @test m.cursor_col == 3  # one past 'e'
        # Up wraps col within the longer line above.
        m.cursor_row = 2; m.cursor_col = 2
        Ressac._move_cursor!(m, 0, -1)
        @test m.cursor_row == 1
        @test m.cursor_col == 2
    end

    @testset "_line_start! / _line_end! / _buffer_start! / _buffer_end!" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["foo bar", "baz", "  quux"]
        m.cursor_row = 1; m.cursor_col = 5
        Ressac._line_start!(m)
        @test m.cursor_col == 1
        Ressac._line_end!(m)
        @test m.cursor_col == lastindex("foo bar") + 1
        Ressac._buffer_end!(m)
        @test m.cursor_row == 3
        @test m.cursor_col == 1
        Ressac._buffer_start!(m)
        @test m.cursor_row == 1
        @test m.cursor_col == 1
    end
```

- [ ] **Step 2: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: `UndefVarError` for the new helpers.

- [ ] **Step 3: Add helpers to `src/tui_buffer.jl`**

Append:

```julia
"""
    _move_cursor!(m, dx, dy)

Move the cursor by `dx` columns and `dy` rows, clamping to buffer
bounds. `col` clamps to `lastindex(line) + 1` (one past EOL).
"""
function _move_cursor!(m::LiveModel, dx::Int, dy::Int)
    m.cursor_row = clamp(m.cursor_row + dy, 1, length(m.buffer))
    line = m.buffer[m.cursor_row]
    m.cursor_col = clamp(m.cursor_col + dx, 1, lastindex(line) + 1)
    return nothing
end

function _line_start!(m::LiveModel)
    m.cursor_col = 1
    return nothing
end

function _line_end!(m::LiveModel)
    m.cursor_col = lastindex(m.buffer[m.cursor_row]) + 1
    return nothing
end

function _buffer_start!(m::LiveModel)
    m.cursor_row = 1
    m.cursor_col = 1
    return nothing
end

function _buffer_end!(m::LiveModel)
    m.cursor_row = length(m.buffer)
    m.cursor_col = 1
    return nothing
end
```

- [ ] **Step 4: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/tui_buffer.jl test/test_tui_buffer.jl
git commit -m "tui_buffer: cursor navigation helpers"
```

### Task B4: Block extraction + `_eval_input!`

**Files:**
- Create: `src/tui_eval.jl`
- Create test cases in: `test/test_tui.jl` (replace v1 content later; for now, add a `tui_eval` testset)
- Modify: `src/Ressac.jl`

- [ ] **Step 1: Write the failing tests**

Add a brand-new file `test/test_tui_eval.jl`:

```julia
using Test
using Ressac

@testset "tui_eval" begin
    @testset "_block_text joins paragraph lines" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["@d1 (",
                    "  pure(:bd)",
                    "  |> fast(2)",
                    ")",
                    "",
                    "@d2 pure(:sn)"]
        m.cursor_row = 2
        text = Ressac._block_text(m)
        @test text == "@d1 (\n  pure(:bd)\n  |> fast(2)\n)"
    end

    @testset "_eval_block! installs the pattern via _route_to_slot!" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=1.0)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["@d1 pure(:bd)"]
            m.cursor_row = 1
            Ressac._eval_block!(m; mode=:immediate, n=0)
            @test haskey(sched.patterns, :d1)
            # last_eval_block records (row_start, row_stop) for the slot.
            @test m.last_eval_block[:d1] == (1, 1)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            Ressac._EVAL_MODE[] = (:immediate, 0)
        end
    end

    @testset "_eval_block! deferred mode queues via schedule_pattern!" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=1.0)
        sched.t_start = time()
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["@d1 pure(:bd)"]
            m.cursor_row = 1
            Ressac._eval_block!(m; mode=:deferred, n=3)
            @test !haskey(sched.patterns, :d1)
            @test haskey(sched.pending, :d1)
            (_, at) = sched.pending[:d1]
            @test at == 3 // 1  # ceil(0) + 3
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            Ressac._EVAL_MODE[] = (:immediate, 0)
        end
    end

    @testset "_eval_block! on blank-line cursor is a no-op" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=1.0)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["@d1 pure(:bd)", "", "@d2 pure(:sn)"]
            m.cursor_row = 2
            Ressac._eval_block!(m; mode=:immediate, n=0)
            @test !haskey(sched.patterns, :d1)
            @test !haskey(sched.patterns, :d2)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "_eval_block! logs errors to m.logs without throwing" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=1.0)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["this is not valid Julia ((("]
            m.cursor_row = 1
            Ressac._eval_block!(m; mode=:immediate, n=0)
            @test any(l -> occursin("ERROR", l), m.logs)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end
end
```

Add to `test/runtests.jl` before the closing `end`:

```julia
    include("test_tui_eval.jl")
```

- [ ] **Step 2: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: errors for undefined `_block_text`, `_eval_block!`.

- [ ] **Step 3: Create `src/tui_eval.jl`**

```julia
"""
    _block_text(m) -> String

Join the paragraph at the cursor into one expression string, separated
by `\\n`. Returns empty if the cursor is on a blank row.
"""
function _block_text(m::LiveModel)
    start, stop = _paragraph_bounds(m)
    stop < start && return ""
    return join(m.buffer[start:stop], "\n")
end

"""
    _block_slot(text) -> Union{Symbol,Nothing}

Recognise a `@dN <body>` opener inside `text` and return `:dN`, or
`nothing` if no such macro is at the start.
"""
function _block_slot(text::AbstractString)
    m = match(r"^\s*@(d\d+)\b", text)
    m === nothing && return nothing
    return Symbol(m.captures[1])
end

"""
    _eval_block!(m; mode::Symbol = :immediate, n::Int = 0)

Evaluate the paragraph at the cursor. `mode` is one of `:immediate` or
`:deferred`; `n` is the +N cycle offset for deferred. Records the slot
target (if any) into `m.last_eval_block`. Errors are appended to
`m.logs`, never re-thrown.
"""
function _eval_block!(m::LiveModel; mode::Symbol = :immediate, n::Int = 0)
    text = _block_text(m)
    isempty(strip(text)) && return
    start, stop = _paragraph_bounds(m)
    slot = _block_slot(text)
    try
        ex = Meta.parse(text)
        prev_mode = _EVAL_MODE[]
        _EVAL_MODE[] = (mode, n)
        try
            Core.eval(Main, ex)
        finally
            _EVAL_MODE[] = prev_mode
        end
        slot === nothing || (m.last_eval_block[slot] = (start, stop))
        _push_log!(m, mode === :immediate ?
            "[INFO] eval $(slot === nothing ? "block" : String(slot))" :
            "[INFO] queued $(slot === nothing ? "block" : String(slot)) → +$n cycles")
    catch err
        _push_log!(m, "[ERROR] $(sprint(showerror, err))")
    end
end
```

In `src/Ressac.jl`, add `include("tui_eval.jl")` after `include("tui_buffer.jl")`:

```julia
include("tui_model.jl")
include("tui_buffer.jl")
include("tui_eval.jl")
```

- [ ] **Step 4: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/tui_eval.jl src/Ressac.jl test/test_tui_eval.jl test/runtests.jl
git commit -m "tui_eval: paragraph block extraction + _eval_block! routing"
```

### Task B5: `_set_mute!` toggle helper

**Files:**
- Create: `src/tui_search.jl` (will also house mute since both manipulate the same line-regex world). Actually — split mute into its own short file: `src/tui_mute.jl`.

Decision: keep mute inside `src/tui_eval.jl` to avoid file proliferation. The function is short and conceptually adjacent (it triggers eval on re-activation).

- Modify: `src/tui_eval.jl`
- Modify: `test/test_tui_eval.jl`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_tui_eval.jl` inside `tui_eval`:

```julia
    @testset "_toggle_mute! comments an active @dN line and unsets the slot" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=1.0)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["@d1 pure(:bd)"]
            m.cursor_row = 1
            Ressac._eval_block!(m; mode=:immediate, n=0)
            @test haskey(sched.patterns, :d1)

            Ressac._toggle_mute!(m)
            @test m.buffer[1] == "# @d1 pure(:bd)"
            @test !haskey(sched.patterns, :d1)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "_toggle_mute! uncomments and re-evals" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=1.0)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["# @d1 pure(:bd)"]
            m.cursor_row = 1
            Ressac._toggle_mute!(m)
            @test m.buffer[1] == "@d1 pure(:bd)"
            @test haskey(sched.patterns, :d1)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "_toggle_mute! on non-@dN line logs a warning" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=1.0)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["# just a comment"]
            m.cursor_row = 1
            Ressac._toggle_mute!(m)
            @test m.buffer[1] == "# just a comment"  # unchanged
            @test any(l -> occursin("not a slot def", l) || occursin("WARN", l), m.logs)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end
```

- [ ] **Step 2: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: undefined `_toggle_mute!`.

- [ ] **Step 3: Append to `src/tui_eval.jl`**

```julia
const _ACTIVE_SLOT_RX   = r"^\s*@(d\d+)\b"
const _COMMENTED_SLOT_RX = r"^\s*#+\s*@(d\d+)\b"

"""
    _toggle_mute!(m)

If the current line is an uncommented `@dN ...` def → comment it and
call `unset_pattern!(:dN)`. If the line is a commented slot def →
uncomment it and re-eval the line through `_eval_block!`. Otherwise
log a warning.
"""
function _toggle_mute!(m::LiveModel)
    line = m.buffer[m.cursor_row]
    if (mt = match(_ACTIVE_SLOT_RX, line)) !== nothing
        slot = Symbol(mt.captures[1])
        m.buffer[m.cursor_row] = "# " * line
        sched = _check_live()
        unset_pattern!(sched, slot)
        _push_log!(m, "[INFO] muted $slot")
    elseif match(_COMMENTED_SLOT_RX, line) !== nothing
        m.buffer[m.cursor_row] = replace(line, r"^\s*#+\s*" => ""; count=1)
        # _eval_block! will pick up the now-uncommented line.
        _eval_block!(m; mode=:immediate, n=0)
    else
        _push_log!(m, "[WARN] m: not a slot def, no-op")
    end
end
```

- [ ] **Step 4: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/tui_eval.jl test/test_tui_eval.jl
git commit -m "tui_eval: _toggle_mute! comments/uncomments + scheduler side-effect"
```

---

## Phase C — Search and goto

### Task C1: `src/tui_search.jl` with `_run_search!` + `_repeat_search!`

**Files:**
- Create: `src/tui_search.jl`
- Create: `test/test_tui_search.jl`
- Modify: `src/Ressac.jl`, `test/runtests.jl`

- [ ] **Step 1: Write the failing tests**

Create `test/test_tui_search.jl`:

```julia
using Test
using Ressac

@testset "tui_search" begin
    function _new_model()
        sched = Scheduler(MockOSCClient(); cps=1.0)
        Ressac.LiveModel(; scheduler=sched,
            buffer=["@d1 pure(:bd)",
                    "# @d1 old",
                    "@d2 pure(:sn)",
                    "@d1 pure(:cp)"])
    end

    @testset "_run_search! forward finds first match below cursor" begin
        m = _new_model()
        m.cursor_row = 1; m.cursor_col = 1
        Ressac._run_search!(m, r"@d1\b"; dir=:forward)
        @test m.cursor_row == 4  # row 1 is exactly at cursor; forward starts after
    end

    @testset "_run_search! backward finds last match above cursor" begin
        m = _new_model()
        m.cursor_row = 4; m.cursor_col = 1
        Ressac._run_search!(m, r"@d1\b"; dir=:backward)
        @test m.cursor_row == 1
    end

    @testset "_run_search! wraps when nothing in original direction" begin
        m = _new_model()
        m.cursor_row = 4; m.cursor_col = 1
        Ressac._run_search!(m, r"@d2\b"; dir=:forward)
        @test m.cursor_row == 3
    end

    @testset "_run_search! ignores commented matches" begin
        m = _new_model()
        m.cursor_row = 1; m.cursor_col = 1
        Ressac._run_search!(m, r"@d1\b"; dir=:forward)
        @test m.cursor_row == 4  # not row 2 (commented)
    end

    @testset "_repeat_search! n/N use stored direction" begin
        m = _new_model()
        m.cursor_row = 1; m.cursor_col = 1
        m.last_search = r"@d1\b"; m.last_search_dir = :forward
        Ressac._repeat_search!(m; reverse=false)  # n
        @test m.cursor_row == 4
        Ressac._repeat_search!(m; reverse=true)   # N
        @test m.cursor_row == 1
    end

    @testset "_run_search! logs and returns when no match anywhere" begin
        m = _new_model()
        Ressac._run_search!(m, r"@d99\b"; dir=:forward)
        @test any(l -> occursin("no match", l), m.logs)
    end
end
```

Add `include("test_tui_search.jl")` to `test/runtests.jl`.

- [ ] **Step 2: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: undefined `_run_search!`, `_repeat_search!`.

- [ ] **Step 3: Create `src/tui_search.jl`**

```julia
const _IS_COMMENTED_RX = r"^\s*#"

_is_commented(line) = match(_IS_COMMENTED_RX, line) !== nothing

"""
    _run_search!(m, rx::Regex; dir=:forward)

Move the cursor to the next/previous row matching `rx` (skipping
commented lines). On success, set `m.last_search` and
`m.last_search_dir`. Wraps if nothing found in the primary direction.
On total miss, logs `[INFO] no match` and leaves the cursor put.
"""
function _run_search!(m::LiveModel, rx::Regex; dir::Symbol = :forward)
    n = length(m.buffer)
    n == 0 && return

    matches(row) = !_is_commented(m.buffer[row]) && match(rx, m.buffer[row]) !== nothing

    if dir === :forward
        # Search from (cursor_row + 1) … n, then wrap 1 … cursor_row.
        for row in (m.cursor_row + 1):n
            if matches(row)
                m.cursor_row = row; m.cursor_col = 1
                m.last_search = rx; m.last_search_dir = dir
                return
            end
        end
        for row in 1:m.cursor_row
            if matches(row)
                m.cursor_row = row; m.cursor_col = 1
                m.last_search = rx; m.last_search_dir = dir
                return
            end
        end
    else  # :backward
        for row in (m.cursor_row - 1):-1:1
            if matches(row)
                m.cursor_row = row; m.cursor_col = 1
                m.last_search = rx; m.last_search_dir = dir
                return
            end
        end
        for row in n:-1:m.cursor_row
            if matches(row)
                m.cursor_row = row; m.cursor_col = 1
                m.last_search = rx; m.last_search_dir = dir
                return
            end
        end
    end
    _push_log!(m, "[INFO] no match for /$(rx.pattern)/")
end

"""
    _repeat_search!(m; reverse=false)

Re-run `m.last_search` in the stored direction (or reversed). No-op if
`last_search` is `nothing`.
"""
function _repeat_search!(m::LiveModel; reverse::Bool = false)
    m.last_search === nothing && return
    dir = m.last_search_dir
    if reverse
        dir = dir === :forward ? :backward : :forward
    end
    _run_search!(m, m.last_search; dir=dir)
end

"""
    _goto_slot!(m, n::Int)

Build the slot regex for `dN` and run a backward search (we want the
latest def). On failure, log and bail.
"""
function _goto_slot!(m::LiveModel, n::Int)
    1 <= n <= 64 || (_push_log!(m, "[ERROR] slot d$n out of range (1..64)"); return)
    rx = Regex("^\\s*@d$n\\b")
    if !any(row -> !_is_commented(m.buffer[row]) && match(rx, m.buffer[row]) !== nothing,
            1:length(m.buffer))
        _push_log!(m, "[INFO] no def for d$n")
        return
    end
    _run_search!(m, rx; dir=:backward)
end
```

Add `include("tui_search.jl")` to `src/Ressac.jl` after `include("tui_eval.jl")`.

- [ ] **Step 4: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/tui_search.jl src/Ressac.jl test/test_tui_search.jl test/runtests.jl
git commit -m "tui_search: regex search + n/N + _goto_slot!"
```

---

## Phase D — Bindings (keystroke dispatch)

This phase glues everything via `TUI.update!`. Because TUI.jl doesn't easily mock `KeyEvent` in unit tests, we test the dispatcher by constructing fake events through a thin wrapper.

### Task D1: Helper to translate a key dict into a model mutation

**Files:**
- Create: `src/tui_bindings.jl`
- Create: `test/test_tui_bindings.jl`
- Modify: `src/Ressac.jl`, `test/runtests.jl`

- [ ] **Step 1: Write the failing tests**

Create `test/test_tui_bindings.jl`:

```julia
using Test
using Ressac

# `_dispatch_key!` is the entry point for tests — it takes a `KeyEvent`-ish
# dict so we don't need to construct real Crossterm events.

function _fake_key(code; mods=String[], kind="Press")
    return (; code=code, modifiers=mods, kind=kind)
end

@testset "tui_bindings" begin
    @testset "insert mode: printable char inserts" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.mode = :insert
        Ressac._dispatch_key!(m, _fake_key("a"))
        @test m.buffer == ["a"]
        @test m.cursor_col == 2
    end

    @testset "insert mode: Enter splits line" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.mode = :insert; m.buffer = ["abc"]; m.cursor_col = 3
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test m.buffer == ["ab", "c"]
    end

    @testset "insert mode: Esc switches to normal" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.mode = :insert
        Ressac._dispatch_key!(m, _fake_key("Esc"))
        @test m.mode === :normal
    end

    @testset "normal mode: i/a/o/O switch to insert" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.mode = :normal; m.buffer = ["xy"]; m.cursor_col = 1
        Ressac._dispatch_key!(m, _fake_key("a"))
        @test m.mode === :insert
        @test m.cursor_col == 2  # cursor advances past current char on `a`

        m.mode = :normal; m.cursor_col = 1
        Ressac._dispatch_key!(m, _fake_key("o"))
        @test m.mode === :insert
        @test m.cursor_row == 2
        @test m.buffer == ["xy", ""]
    end

    @testset "normal mode: hjkl + 0/$ navigate" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.mode = :normal; m.buffer = ["abc", "defg"]; m.cursor_row = 1; m.cursor_col = 2
        Ressac._dispatch_key!(m, _fake_key("l"))
        @test m.cursor_col == 3
        Ressac._dispatch_key!(m, _fake_key("j"))
        @test m.cursor_row == 2
        Ressac._dispatch_key!(m, _fake_key("0"))
        @test m.cursor_col == 1
        Ressac._dispatch_key!(m, _fake_key("\$"))
        @test m.cursor_col == lastindex("defg") + 1
    end

    @testset "normal mode: dd deletes the current line" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.mode = :normal; m.buffer = ["a", "b", "c"]; m.cursor_row = 2
        Ressac._dispatch_key!(m, _fake_key("d"))  # primer
        @test m.pending_chord === :d
        Ressac._dispatch_key!(m, _fake_key("d"))  # commit
        @test m.buffer == ["a", "c"]
        @test m.pending_chord === :none
    end

    @testset "normal mode: count_prefix accumulates digits" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key("2"))
        @test m.count_prefix == 2
        Ressac._dispatch_key!(m, _fake_key("3"))
        @test m.count_prefix == 23
    end

    @testset "normal mode: gd<digits> chord triggers goto" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=1.0)
        m = Ressac.LiveModel(; scheduler=sched,
            buffer=["@d1 pure(:bd)", "", "@d2 pure(:sn)", "", "@d1 pure(:cp)"])
        m.mode = :normal; m.cursor_row = 3
        Ressac._dispatch_key!(m, _fake_key("g"))
        @test m.pending_chord === :g
        Ressac._dispatch_key!(m, _fake_key("d"))
        @test m.pending_chord === :gd
        Ressac._dispatch_key!(m, _fake_key("1"))
        @test m.chord_digits == "1"
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test m.pending_chord === :none
        # `gd1` from row 3 should land on the latest @d1 def. Backward search
        # finds row 1 (rows above the cursor); 5 is below.
        @test m.cursor_row == 1
    end
end
```

Add `include("test_tui_bindings.jl")` to `test/runtests.jl`.

- [ ] **Step 2: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: undefined `_dispatch_key!`.

- [ ] **Step 3: Create `src/tui_bindings.jl`**

```julia
"""
    _dispatch_key!(m, evt)

Mode-aware keystroke router. `evt` must expose `code::String`,
`modifiers::Vector{String}`, `kind::String`. Only acts on Press events.
"""
function _dispatch_key!(m::LiveModel, evt)
    evt.kind == "Press" || return
    if m.mode === :insert
        _handle_insert!(m, evt)
    elseif m.mode === :normal
        _handle_normal!(m, evt)
    elseif m.mode === :visual_line
        _handle_visual!(m, evt)
    elseif m.mode === :command
        _handle_command!(m, evt)
    end
end

# ---------------------------------------------------------------------
# Insert mode
# ---------------------------------------------------------------------
function _handle_insert!(m::LiveModel, evt)
    code = evt.code
    if code == "Esc"
        m.mode = :normal
        # Snap cursor back if it went one past EOL.
        line = m.buffer[m.cursor_row]
        m.cursor_col = clamp(m.cursor_col, 1, max(1, lastindex(line)))
    elseif code == "Enter"
        _split_line!(m)
    elseif code == "Backspace"
        _backspace!(m)
    elseif code == "Left"
        _move_cursor!(m, -1, 0)
    elseif code == "Right"
        _move_cursor!(m, +1, 0)
    elseif code == "Up"
        _move_cursor!(m, 0, -1)
    elseif code == "Down"
        _move_cursor!(m, 0, +1)
    elseif length(code) == 1
        _insert_char!(m, first(code))
    end
end

# ---------------------------------------------------------------------
# Normal mode
# ---------------------------------------------------------------------
function _handle_normal!(m::LiveModel, evt)
    code = evt.code

    # Chord resolution: if we're in :gd, gobble digits / non-digits.
    if m.pending_chord === :gd
        if length(code) == 1 && isdigit(only(code))
            m.chord_digits *= code
            return
        else
            # Resolve.
            digits = m.chord_digits
            m.pending_chord = :none
            m.chord_digits = ""
            if isempty(digits)
                _push_log!(m, "[ERROR] gd: no slot given")
            else
                _goto_slot!(m, parse(Int, digits))
            end
            # Replay non-Enter, non-Esc keys.
            if code != "Enter" && code != "Esc"
                _handle_normal!(m, evt)
            end
            return
        end
    end

    # :g primer awaiting :d
    if m.pending_chord === :g
        if code == "d"
            m.pending_chord = :gd
            m.chord_digits = ""
        else
            m.pending_chord = :none
        end
        return
    end

    # :d primer awaiting :d (for `dd`)
    if m.pending_chord === :d
        if code == "d"
            n = max(m.count_prefix, 1)
            m.count_prefix = 0
            _yank_lines!(m, n)
            for _ in 1:n
                length(m.buffer) == 1 && m.buffer[1] == "" && break
                _delete_line!(m)
            end
        end
        m.pending_chord = :none
        return
    end

    # :y primer awaiting :y (for `yy`)
    if m.pending_chord === :y
        if code == "y"
            n = max(m.count_prefix, 1)
            m.count_prefix = 0
            _yank_lines!(m, n)
        end
        m.pending_chord = :none
        return
    end

    # Plain keys.
    if code == "i"
        m.mode = :insert
    elseif code == "a"
        m.mode = :insert
        line = m.buffer[m.cursor_row]
        m.cursor_col = min(m.cursor_col + 1, lastindex(line) + 1)
    elseif code == "o"
        # Open new line below.
        insert!(m.buffer, m.cursor_row + 1, "")
        m.cursor_row += 1
        m.cursor_col = 1
        m.mode = :insert
    elseif code == "O"
        insert!(m.buffer, m.cursor_row, "")
        m.cursor_col = 1
        m.mode = :insert
    elseif code == "h" || code == "Left"
        _move_cursor!(m, -1, 0)
    elseif code == "l" || code == "Right"
        _move_cursor!(m, +1, 0)
    elseif code == "j" || code == "Down"
        _move_cursor!(m, 0, +1)
    elseif code == "k" || code == "Up"
        _move_cursor!(m, 0, -1)
    elseif code == "0" && m.count_prefix == 0
        _line_start!(m)
    elseif code == "\$"
        _line_end!(m)
    elseif code == "g"
        if m.pending_chord === :none
            m.pending_chord = :g
        end
    elseif code == "G"
        _buffer_end!(m)
    elseif code == "d"
        m.pending_chord = :d
    elseif code == "y"
        m.pending_chord = :y
    elseif code == "x"
        # Delete char under cursor.
        line = m.buffer[m.cursor_row]
        if m.cursor_col <= lastindex(line)
            m.buffer[m.cursor_row] =
                line[1:prevind(line, m.cursor_col)] *
                (m.cursor_col + 1 > lastindex(line) ? "" : line[nextind(line, m.cursor_col):end])
        end
    elseif code == "p"
        _paste_lines!(m; before=false)
    elseif code == "P"
        _paste_lines!(m; before=true)
    elseif code == "m"
        _toggle_mute!(m)
    elseif code == "V"
        m.mode = :visual_line
        m.visual_anchor = (m.cursor_row, m.cursor_col)
    elseif code == "e"
        n = m.count_prefix
        m.count_prefix = 0
        if n == 0
            _eval_block!(m; mode=:immediate, n=0)
        else
            _eval_block!(m; mode=:deferred, n=n)
        end
    elseif code == "n"
        _repeat_search!(m; reverse=false)
    elseif code == "N"
        _repeat_search!(m; reverse=true)
    elseif code == ":" || code == "/" || code == "?"
        m.mode = :command
        m.command_prefix = first(code)
        m.command_buffer = ""
    elseif length(code) == 1 && isdigit(only(code))
        m.count_prefix = m.count_prefix * 10 + parse(Int, code)
    elseif code == "Esc"
        # Cancel any partial state.
        m.count_prefix = 0
        m.pending_chord = :none
        m.chord_digits = ""
    end
end

# ---------------------------------------------------------------------
# Visual line mode
# ---------------------------------------------------------------------
function _handle_visual!(m::LiveModel, evt)
    code = evt.code
    if code == "Esc"
        m.mode = :normal
        m.visual_anchor = nothing
    elseif code == "j" || code == "Down"
        _move_cursor!(m, 0, +1)
    elseif code == "k" || code == "Up"
        _move_cursor!(m, 0, -1)
    elseif code == "G"
        _buffer_end!(m)
    elseif code == "g"
        # Quick gg without chord state — visual mode is brief.
        _buffer_start!(m)
    elseif code == "y"
        _yank_selection!(m)
        m.mode = :normal
        m.visual_anchor = nothing
    elseif code == "d"
        _yank_selection!(m)
        _delete_selection!(m)
        m.mode = :normal
        m.visual_anchor = nothing
    elseif code == "m"
        for row in _visual_range(m)
            m.cursor_row = row
            _toggle_mute!(m)
        end
        m.mode = :normal
        m.visual_anchor = nothing
    elseif code == "e"
        rs, re = _visual_range(m)
        n = m.count_prefix
        m.count_prefix = 0
        m.cursor_row = rs
        # Temporarily widen buffer view: build text from rs..re directly.
        text = join(m.buffer[rs:re], "\n")
        try
            ex = Meta.parse(text)
            slot = _block_slot(text)
            prev = _EVAL_MODE[]
            _EVAL_MODE[] = n == 0 ? (:immediate, 0) : (:deferred, n)
            try
                Core.eval(Main, ex)
            finally
                _EVAL_MODE[] = prev
            end
            slot === nothing || (m.last_eval_block[slot] = (rs, re))
            _push_log!(m, "[INFO] eval block rows $rs:$re")
        catch err
            _push_log!(m, "[ERROR] $(sprint(showerror, err))")
        end
        m.mode = :normal
        m.visual_anchor = nothing
    end
end

_visual_range(m::LiveModel) =
    let (ar, _) = m.visual_anchor
        a, b = minmax(ar, m.cursor_row)
        (a, b)
    end

function _yank_selection!(m::LiveModel)
    rs, re = _visual_range(m)
    m.yank = m.buffer[rs:re]
end

function _delete_selection!(m::LiveModel)
    rs, re = _visual_range(m)
    deleteat!(m.buffer, rs:re)
    isempty(m.buffer) && push!(m.buffer, "")
    m.cursor_row = clamp(rs, 1, length(m.buffer))
    m.cursor_col = 1
end

function _yank_lines!(m::LiveModel, n::Int)
    n = clamp(n, 1, length(m.buffer) - m.cursor_row + 1)
    m.yank = m.buffer[m.cursor_row:(m.cursor_row + n - 1)]
end

function _paste_lines!(m::LiveModel; before::Bool=false)
    isempty(m.yank) && return
    insert_at = before ? m.cursor_row : m.cursor_row + 1
    for (i, line) in enumerate(m.yank)
        insert!(m.buffer, insert_at + i - 1, line)
    end
    m.cursor_row = insert_at
    m.cursor_col = 1
end

# ---------------------------------------------------------------------
# Command mode (:, /, ?)
# ---------------------------------------------------------------------
function _handle_command!(m::LiveModel, evt)
    code = evt.code
    if code == "Esc"
        m.mode = :normal
        m.command_buffer = ""
    elseif code == "Enter"
        _execute_command!(m)
        m.mode = :normal
        m.command_buffer = ""
    elseif code == "Backspace"
        isempty(m.command_buffer) && return
        m.command_buffer = m.command_buffer[1:prevind(m.command_buffer, end)]
    elseif length(code) == 1
        m.command_buffer *= code
    end
end

function _execute_command!(m::LiveModel)
    prefix = m.command_prefix
    body = m.command_buffer
    if prefix == ':'
        _execute_ex_command!(m, body)
    elseif prefix == '/'
        try
            rx = Regex(body)
            _run_search!(m, rx; dir=:forward)
        catch err
            _push_log!(m, "[ERROR] bad regex: $(sprint(showerror, err))")
        end
    elseif prefix == '?'
        try
            rx = Regex(body)
            _run_search!(m, rx; dir=:backward)
        catch err
            _push_log!(m, "[ERROR] bad regex: $(sprint(showerror, err))")
        end
    end
end

function _execute_ex_command!(m::LiveModel, body::AbstractString)
    body = strip(body)
    if body == "q" || body == "quit"
        m.quit = true
    elseif startswith(body, "cps ")
        try
            x = parse(Float64, strip(body[5:end]))
            set_cps!(m.scheduler, x)
            _push_log!(m, "[INFO] cps = $x")
        catch err
            _push_log!(m, "[ERROR] cps: $(sprint(showerror, err))")
        end
    elseif (mt = match(r"^goto\s+d(\d+)$", body)) !== nothing
        _goto_slot!(m, parse(Int, mt.captures[1]))
    else
        _push_log!(m, "[ERROR] unknown command: $body")
    end
end
```

Add `include("tui_bindings.jl")` to `src/Ressac.jl` after `include("tui_search.jl")`.

- [ ] **Step 4: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/tui_bindings.jl src/Ressac.jl test/test_tui_bindings.jl test/runtests.jl
git commit -m "tui_bindings: keystroke dispatch across insert/normal/visual/command"
```

### Task D2: Visual + yank + command mode tests

**Files:**
- Modify: `test/test_tui_bindings.jl`

(The dispatcher already implements visual, yank, command — but only the normal-mode entries are tested. Fill in the gaps so regressions are caught.)

- [ ] **Step 1: Write the failing tests**

Append to `test/test_tui_bindings.jl` inside `tui_bindings`:

```julia
    @testset "visual: V + j extends selection; y yanks; Esc cancels" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["a", "b", "c", "d"]
        m.cursor_row = 1; m.cursor_col = 1; m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key("V"))
        @test m.mode === :visual_line
        @test m.visual_anchor == (1, 1)
        Ressac._dispatch_key!(m, _fake_key("j"))
        Ressac._dispatch_key!(m, _fake_key("j"))
        Ressac._dispatch_key!(m, _fake_key("y"))
        @test m.mode === :normal
        @test m.yank == ["a", "b", "c"]
    end

    @testset "visual: d deletes selection and yanks" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["a", "b", "c", "d"]
        m.cursor_row = 2; m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key("V"))
        Ressac._dispatch_key!(m, _fake_key("j"))
        Ressac._dispatch_key!(m, _fake_key("d"))
        @test m.buffer == ["a", "d"]
        @test m.yank == ["b", "c"]
        @test m.mode === :normal
    end

    @testset "yy / p round-trip a single line" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["one", "two"]
        m.cursor_row = 1; m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key("y"))
        Ressac._dispatch_key!(m, _fake_key("y"))
        @test m.yank == ["one"]
        m.cursor_row = 2
        Ressac._dispatch_key!(m, _fake_key("p"))
        @test m.buffer == ["one", "two", "one"]
    end

    @testset "command mode: :q sets quit" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key(":"))
        @test m.mode === :command
        Ressac._dispatch_key!(m, _fake_key("q"))
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test m.quit
        @test m.mode === :normal
    end

    @testset "command mode: :cps 0.75 updates the scheduler" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        m = Ressac.LiveModel(; scheduler=sched); m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key(":"))
        for c in "cps 0.75"
            Ressac._dispatch_key!(m, _fake_key(string(c)))
        end
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test sched.cps == 0.75
    end

    @testset "command mode: /@d1 jumps forward" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient()))
        m.buffer = ["foo", "@d1 pure(:bd)", "bar"]
        m.cursor_row = 1; m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key("/"))
        for c in "@d1"
            Ressac._dispatch_key!(m, _fake_key(string(c)))
        end
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        @test m.cursor_row == 2
    end
```

- [ ] **Step 2: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass (since the dispatcher already implements these paths).

- [ ] **Step 3: No implementation needed**

Skip — the prior task covered the code.

- [ ] **Step 4: Sanity-rerun**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add test/test_tui_bindings.jl
git commit -m "tui_bindings: tests for visual + yank/paste + command modes"
```

---

## Phase E — View rendering

### Task E1: `src/tui_view.jl` with the main `TUI.view`

**Files:**
- Create: `src/tui_view.jl`
- Modify: `test/test_tui.jl` (replace v1 content)
- Modify: `src/Ressac.jl`

- [ ] **Step 1: Write the failing test**

Replace `test/test_tui.jl` with:

```julia
using Test
using Ressac
using TerminalUserInterfaces
const TUI = TerminalUserInterfaces

@testset "tui (non-interactive)" begin
    @testset "live API helpers error without an active session" begin
        Ressac._LIVE_SCHEDULER[] = nothing
        @test_throws ErrorException d!(:d1, pure(:bd))
        @test_throws ErrorException unset!(:d1)
        @test_throws ErrorException hush_all!()
        @test_throws ErrorException cps!(0.5)
    end

    @testset "TUI.view returns a non-throwing widget tree" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        m = Ressac.LiveModel(; scheduler=sched)
        @test TUI.view(m) !== nothing
        # With patterns + pending + selection, view still doesn't throw.
        m.buffer = ["@d1 pure(:bd)", "@d2 pure(:sn)"]
        set_pattern!(sched, :d1, pure(:bd))
        schedule_pattern!(sched, :d2, pure(:sn), 4 // 1)
        m.last_eval_block[:d1] = (1, 1)
        m.mode = :visual_line; m.visual_anchor = (1, 1); m.cursor_row = 2
        @test TUI.view(m) !== nothing
    end

    @testset "command-mode prompt shows in the rendered tree" begin
        mock = MockOSCClient()
        m = Ressac.LiveModel(; scheduler=Scheduler(mock; cps=0.5))
        m.mode = :command; m.command_prefix = ':'; m.command_buffer = "cps 1.0"
        widget = TUI.view(m)
        @test widget !== nothing
    end
end
```

- [ ] **Step 2: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: errors `UndefVarError: view` (or method ambiguity if v1 still exists).

- [ ] **Step 3: Create `src/tui_view.jl`**

```julia
function TUI.init!(m::LiveModel, ::TUI.TerminalBackend)
    _push_log!(m, "[INFO] Ressac live — i to edit, Esc to normal, :q to quit")
end

function TUI.update!(m::LiveModel, evt::TUI.KeyEvent)
    _dispatch_key!(m, (; code=TUI.keycode(evt),
                        modifiers=TUI.keymodifier(evt),
                        kind=evt.data.kind))
end

function TUI.view(m::LiveModel)
    status = _activity_widget(m)
    editor = _editor_pane(m)
    cmd    = _command_line(m)
    logs   = _logs_pane(m)
    TUI.Layout(;
        widgets = [status, editor, cmd, logs],
        constraints = [TUI.Min(3), TUI.Percent(60), TUI.Min(3), TUI.Min(8)],
        orientation = :vertical,
    )
end

function _activity_widget(m::LiveModel)
    sched = m.scheduler
    parts = String[]
    push!(parts, "$(round(sched.cps; digits=3))cps")
    push!(parts, _cycle_indicator(sched))
    push!(parts, "│")
    for (slot, _) in sched.patterns
        push!(parts, "$(String(slot))" * _slot_grid(sched, slot))
    end
    for (slot, (_, at)) in sched.pending
        push!(parts, "$(String(slot)) ⏱→cyc$(Int(at))")
    end
    push!(parts, "│ $(uppercase(String(m.mode)))")
    text = join(parts, "  ")
    return _zone("ressac", text, TUI.Crayon(; bold=true))
end

function _cycle_indicator(s::Scheduler)
    s.t_start == 0.0 && return "▹▹▹▹"
    cur = (time() - s.t_start) * s.cps
    pos = floor(Int, (cur - floor(cur)) * 4) + 1
    glyphs = ['▹', '▹', '▹', '▹']
    1 <= pos <= 4 && (glyphs[pos] = '▸')
    return String(glyphs)
end

function _slot_grid(s::Scheduler, slot::Symbol)
    # Most recent cycle's pattern, sampled at 4 cells. Cell lit if
    # last_fired_at is recent AND the event start falls in that quarter.
    haskey(s.last_fired_at, slot) || return "◦◦◦◦"
    fresh = (time() - s.last_fired_at[slot]) < 0.2
    fresh || return "◦◦◦◦"
    p = s.patterns[slot]
    cur = floor((time() - s.t_start) * s.cps)
    events = p(Rational{Int64}(Int(cur)), Rational{Int64}(Int(cur) + 1))
    cells = ['◦', '◦', '◦', '◦']
    for ev in events
        offset = Float64(ev.start) - cur
        idx = clamp(floor(Int, offset * 4) + 1, 1, 4)
        cells[idx] = '•'
    end
    return String(cells)
end

function _editor_pane(m::LiveModel)
    lines = String[]
    for (i, line) in enumerate(m.buffer)
        prefix = ""
        if m.mode === :visual_line && m.visual_anchor !== nothing
            rs, re = _visual_range(m)
            if rs <= i <= re
                prefix = "│ "
            end
        end
        marker = _active_marker(m, i)
        # Cursor: show a `▌` at insert position for the cursor row.
        if i == m.cursor_row && m.mode in (:insert, :normal)
            col = m.cursor_col
            cursor_line = if col > lastindex(line)
                line * "▌"
            else
                line[1:prevind(line, col)] * "▌" * line[col:end]
            end
            push!(lines, prefix * cursor_line * marker)
        else
            push!(lines, prefix * line * marker)
        end
    end
    text = join(lines, "\n")
    return _zone("buffer", text, TUI.Crayon())
end

function _active_marker(m::LiveModel, row::Int)
    for (slot, (rs, re)) in m.last_eval_block
        rs <= row <= re || continue
        haskey(m.scheduler.patterns, slot) || continue
        return "  ▶"
    end
    return ""
end

function _command_line(m::LiveModel)
    text = m.mode === :command ? "$(m.command_prefix)$(m.command_buffer)█" : " "
    return _zone("cmd", text, TUI.Crayon(; foreground=:green))
end

function _logs_pane(m::LiveModel)
    text = isempty(m.logs) ? "(no logs)" : join(last(m.logs, 8), "\n")
    return _zone("logs", text, TUI.Crayon(; foreground=:blue))
end

function _zone(title::AbstractString, text::AbstractString, style)
    words = TUI.make_words(text, style)
    isempty(words) && push!(words, TUI.Word(" ", style))
    TUI.Paragraph(TUI.Block(; title=String(title)), words, 1, Ref{Int}(0))
end
```

Add `include("tui_view.jl")` to `src/Ressac.jl` after `include("tui_bindings.jl")`.

- [ ] **Step 4: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/tui_view.jl src/Ressac.jl test/test_tui.jl
git commit -m "tui_view: activity widget + editor + command + logs panels"
```

---

## Phase F — Wiring

### Task F1: Replace `src/tui.jl` with the slim entry-point

**Files:**
- Modify: `src/tui.jl`

- [ ] **Step 1: Baseline**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass.

- [ ] **Step 2: Replace the file**

Replace the entire content of `src/tui.jl` with:

```julia
# Entry point for the multi-line TUI. The real work lives in
# `tui_model.jl`, `tui_buffer.jl`, `tui_eval.jl`, `tui_search.jl`,
# `tui_bindings.jl`, and `tui_view.jl`, which are all included by
# `Ressac.jl` before this file. This module just defines the public
# session-management API: `start_live!`, `stop_live!`, `restart_live!`,
# `live`, plus the implicit-scheduler helpers (`d!`, `unset!`,
# `hush_all!`, `cps!`).

const _LIVE_SCHEDULER = Ref{Union{Scheduler,Nothing}}(nothing)

function _check_live()
    s = _LIVE_SCHEDULER[]
    s === nothing && error("No live scheduler — call start_live!() or live() first.")
    return s
end

d!(slot::Symbol, p::Pattern) = set_pattern!(_check_live(), slot, p)
unset!(slot::Symbol)         = unset_pattern!(_check_live(), slot)
hush_all!()                  = hush!(_check_live())
cps!(x::Real)                = set_cps!(_check_live(), x)

function start_live!(; host::AbstractString = "127.0.0.1",
                       port::Integer = 57120,
                       cps::Real = 0.5,
                       lookahead::Real = 0.05)
    if _LIVE_SCHEDULER[] !== nothing
        @warn "A live session is already running — returning the existing scheduler."
        return _LIVE_SCHEDULER[]
    end
    client = OSCClient(host, port)
    sched  = Scheduler(client; cps, lookahead)
    _LIVE_SCHEDULER[] = sched
    start!(sched)
    return sched
end

function stop_live!()
    s = _LIVE_SCHEDULER[]
    s === nothing && return nothing
    stop!(s); hush!(s); _LIVE_SCHEDULER[] = nothing
    return nothing
end

restart_live!(; kwargs...) = (stop_live!(); start_live!(; kwargs...))

function live(; host::AbstractString = "127.0.0.1",
                port::Integer = 57120,
                cps::Real = 0.5,
                lookahead::Real = 0.05)
    existed = _LIVE_SCHEDULER[] !== nothing
    sched = existed ? _LIVE_SCHEDULER[] : start_live!(; host, port, cps, lookahead)
    try
        TUI.app(LiveModel(; scheduler=sched))
    finally
        existed || stop_live!()
    end
    return nothing
end
```

- [ ] **Step 3: Update the include order in `src/Ressac.jl`**

The `include` order in `src/Ressac.jl` must be:

```julia
include("core.jl")
include("combinators.jl")
include("algebra.jl")
include("mininotation.jl")
include("osc.jl")
include("scheduler.jl")
include("tui_model.jl")     # needs Scheduler
include("tui_buffer.jl")    # needs LiveModel
include("tui_eval.jl")      # needs LiveModel + buffer helpers
include("tui_search.jl")    # needs LiveModel
include("tui_bindings.jl")  # needs everything above
include("tui_view.jl")      # needs everything above
include("tui.jl")           # needs LiveModel
include("live_api.jl")      # needs _check_live (from tui.jl)
```

If the current `src/Ressac.jl` order isn't this, fix it. Ensure no duplicate `_LIVE_SCHEDULER` definition.

- [ ] **Step 4: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/tui.jl src/Ressac.jl
git commit -m "tui: slim entry-point delegating to tui_* submodules"
```

### Task F2: Update precompile workload for the new TUI

**Files:**
- Modify: `src/Ressac.jl`

- [ ] **Step 1: Baseline**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass.

- [ ] **Step 2: Extend the workload**

In `src/Ressac.jl`, append the following inside the `@compile_workload begin ... end` block (after the existing `_route_to_slot!` exercises):

```julia
    # TUI dispatch paths — exercise the dispatcher in normal/insert
    # to lock in compile artefacts for editor keystrokes.
    m = LiveModel(; scheduler=sched)
    _LIVE_SCHEDULER[] = sched
    try
        m.mode = :insert
        _dispatch_key!(m, (; code="@", modifiers=String[], kind="Press"))
        _dispatch_key!(m, (; code="d", modifiers=String[], kind="Press"))
        _dispatch_key!(m, (; code="1", modifiers=String[], kind="Press"))
        _dispatch_key!(m, (; code="Esc", modifiers=String[], kind="Press"))
        _dispatch_key!(m, (; code="e", modifiers=String[], kind="Press"))
        # Goto / search.
        _dispatch_key!(m, (; code="g", modifiers=String[], kind="Press"))
        _dispatch_key!(m, (; code="d", modifiers=String[], kind="Press"))
        _dispatch_key!(m, (; code="1", modifiers=String[], kind="Press"))
        _dispatch_key!(m, (; code="Enter", modifiers=String[], kind="Press"))
        # View rendering.
        TUI.view(m)
    finally
        _LIVE_SCHEDULER[] = nothing
    end
```

- [ ] **Step 3: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all pass (precompile slightly heavier; runtime smoother).

- [ ] **Step 4: Smoke check**

Run: `julia --project=. -e 'using Ressac; m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient())); @time TUI.view(m)' 2>&1 | tail -3`
Expected: view rendering well under 10 ms after the precompile.

- [ ] **Step 5: Commit**

```bash
git add src/Ressac.jl
git commit -m "precompile: cover the v2 TUI dispatch + view paths"
```

---

## Phase G — Final cleanups

### Task G1: Manual smoke test plan + commit

**Files:**
- Create: `docs/journal/20260519_multiline_tui_smoke.md`

- [ ] **Step 1: Write a smoke-test checklist**

Create `docs/journal/20260519_multiline_tui_smoke.md`:

```markdown
# Multi-line TUI smoke test

Run inside `nix develop`:

```
just audio       # terminal 1 — wait for "SuperDirt listening on UDP 57120"
just live        # terminal 2 — TUI opens
```

In the TUI:

1. `i` to enter insert mode.
2. Type `@d1 p"bd hh sn hh" |> fast(2)`.
3. `Esc` then `e`. Expect immediate audio (bd-hh-sn-hh at double speed).
4. `i`, edit to `@d1 p"bd*4 sn"`. `Esc`, then `2e`. Expect audio swap at the next musical boundary +2 cycles.
5. `m` on the line. Expect silence and `# @d1 ...` in the buffer.
6. `m` again. Expect audio returns.
7. New line: `o`, `@d2 p"cp ~ cp cp"`, `Esc`, `e`. Both d1 and d2 play.
8. `gd1<Enter>` jumps to the d1 def.
9. `V`, `j`, `j`, `y`. Yanked 3 lines.
10. `p` pastes them below.
11. `:cps 0.75<Enter>` changes tempo.
12. `:q` quits.

If anything misbehaves, look at the Logs pane for `[KEY]` / `[INFO]` / `[ERROR]` lines.
```

- [ ] **Step 2: Commit**

```bash
git add docs/journal/20260519_multiline_tui_smoke.md
git commit -m "docs: smoke test plan for multi-line TUI"
```

### Task G2: Verify nothing was orphaned

**Files:** none.

- [ ] **Step 1: List dead exports / dead helpers**

Run:
```bash
grep -rE "(_eval_input!|history::Vector|input::String\s*=\s*\"\")" src/ test/ || true
```

Expected: empty output (no leftover v1 LiveModel fields, no leftover `_eval_input!`).

- [ ] **Step 2: Final test pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: all green, count exceeds 200 tests.

- [ ] **Step 3: No commit needed**

Just a check.

---

## Self-review summary

- Spec §3.1 slot macros → Task A9.
- Spec §3.2 curried combinators → Tasks A1–A4.
- Spec §3.3 scheduler pending/last_fired_at → Tasks A5–A6.
- Spec §3.4 `_EVAL_MODE` + `_route_to_slot!` → Task A8.
- Spec §4.1 LiveModel struct → Task B1.
- Spec §4.2 mode state machine → Tasks D1 (dispatch).
- Spec §4.3 insert bindings → Task D1.
- Spec §4.4 normal bindings → Task D1.
- Spec §4.5 mute → Task B5.
- Spec §4.6 goto + chord → Task C1.
- Spec §4.7 paragraph → Task B2 (via `_paragraph_bounds`).
- Spec §4.8 active marker → Task E1 (`_active_marker`).
- Spec §4.9 visual mode → Task D1 + D2.
- Spec §4.10 command line + search → Task D1 + D2.
- Spec §4.11 yank/paste → Task D1 + D2.
- Spec §4.12 activity widget → Task E1 (`_activity_widget`).
- Spec §5 file layout → reflected in this plan's file list.
- Spec §6 test strategy → tests in every Phase A/B/C/D/E.
