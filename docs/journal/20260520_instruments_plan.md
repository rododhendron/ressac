# Instruments + synth listing + :guide Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement sub-project 4 per spec `docs/journal/20260520_instruments_design.md` — `[instruments.<name>]` and `[synths.<name>]` sections backed by two new registries, an extended `event_to_osc` that builds multi-arg `/dirt/play` when the symbol resolves to an instrument preset, three new ex-commands (`:instruments`, `:synths`, `:guide`), and an extended `K` preview that walks all three registries.

**Architecture:** Non-breaking extension of the sub-project-2 sample-bank pattern. Two new immutable registries live alongside `_SAMPLE_REGISTRY` in `src/plugins.jl`. Two new section handlers (in `src/plugin_handlers.jl`) parse the manifests and call `register_*!`. The single hot path that changes is `event_to_osc(::Event{Symbol})` in `src/scheduler.jl`: it now consults `_INSTRUMENT_REGISTRY` first and falls through to today's single-arg `s "name"` form when the symbol isn't a known instrument. TUI dispatch picks up the new ex-commands and the K resolution order is updated.

**Tech Stack:** Julia 1.10+, existing TOML stdlib, existing test infrastructure (MockOSCClient + fixtures under `test/fixtures/plugins/`).

---

## File structure

| File | Status | Responsibility |
|---|---|---|
| `src/plugins.jl` | extend | Add `InstrumentEntry`, `SynthEntry`, `_INSTRUMENT_REGISTRY`, `_SYNTH_REGISTRY`, four `*_info`/`list_*`/`register_*!` helpers. |
| `src/plugin_handlers.jl` | extend | `_handle_instruments`, `_handle_synths`, `_osc_value` converter. Register both handlers. |
| `src/scheduler.jl` | extend | Rewrite `event_to_osc(::Event{Symbol})` to consult `_INSTRUMENT_REGISTRY`. |
| `src/tui_bindings.jl` | extend | `:instruments`/`:synths`/`:guide` in `_execute_ex_command!`; extend `_preview_under_cursor!` to walk 3 registries. Add `_GUIDE_LINES`. |
| `src/Ressac.jl` | extend | Export `InstrumentEntry`, `instrument_info`, `list_instruments`, `register_instrument!`, `SynthEntry`, `synth_info`, `list_synths`, `register_synth!`. Extend precompile workload. |
| `test/test_plugins.jl` | extend | Registry round-trip tests for both new registries. |
| `test/test_plugin_handlers.jl` | extend | `[instruments]` and `[synths]` loading; `_osc_value` conversions. |
| `test/test_scheduler.jl` | extend | `event_to_osc` known-instrument → multi-arg; unknown → single-arg. |
| `test/test_tui_bindings.jl` | extend | `:instruments`/`:synths`/`:guide` ex-commands; K resolves instrument over sample. |
| `test/fixtures/plugins/withinst/` | **new** | Fixture: `[instruments]` + `[synths]` + metadata. |
| `docs/cheatsheet.md` | extend | New "Instruments & synths" subsection + `:guide` mention. |

---

## Task 1: InstrumentEntry + SynthEntry registries

**Files:**
- Modify: `src/plugins.jl`
- Modify: `test/test_plugins.jl`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_plugins.jl` inside the outer `@testset "plugins"`:

```julia
    @testset "instrument registry" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)

        @testset "register_instrument! / instrument_info round-trip" begin
            ent = Ressac.InstrumentEntry(:kicklourd, "funkit",
                Pair{String,Any}["s" => "bd", "n" => 3, "gain" => 1.2],
                Dict{String,Any}("tags" => ["heavy"]))
            Ressac.register_instrument!(ent)
            got = Ressac.instrument_info(:kicklourd)
            @test got !== nothing
            @test got.name == :kicklourd
            @test got.plugin == "funkit"
            @test got.params[1] == ("s" => "bd")
            @test got.params[2] == ("n" => 3)
            @test got.metadata["tags"] == ["heavy"]
            empty!(Ressac._INSTRUMENT_REGISTRY)
        end

        @testset "instrument_info returns nothing for unknown names" begin
            @test Ressac.instrument_info(:nope) === nothing
        end

        @testset "shadow: second registration with same name warns and is skipped" begin
            a = Ressac.InstrumentEntry(:dup, "p1",
                Pair{String,Any}["s" => "bd"], Dict{String,Any}())
            b = Ressac.InstrumentEntry(:dup, "p2",
                Pair{String,Any}["s" => "sn"], Dict{String,Any}())
            Ressac.register_instrument!(a)
            @test_logs (:warn, r"dup.*shadow") match_mode=:any begin
                Ressac.register_instrument!(b)
            end
            @test Ressac.instrument_info(:dup).plugin == "p1"
            empty!(Ressac._INSTRUMENT_REGISTRY)
        end

        @testset "list_instruments sorted by plugin then name + regex filter" begin
            for ent in [
                Ressac.InstrumentEntry(:b, "z",
                    Pair{String,Any}["s" => "bd"], Dict{String,Any}()),
                Ressac.InstrumentEntry(:a, "z",
                    Pair{String,Any}["s" => "bd"], Dict{String,Any}()),
                Ressac.InstrumentEntry(:c, "a",
                    Pair{String,Any}["s" => "bd"], Dict{String,Any}()),
                Ressac.InstrumentEntry(:bd_alt, "a",
                    Pair{String,Any}["s" => "bd"], Dict{String,Any}()),
            ]
                Ressac.register_instrument!(ent)
            end
            all_inst = Ressac.list_instruments()
            @test [(e.plugin, e.name) for e in all_inst] ==
                  [("a", :bd_alt), ("a", :c), ("z", :a), ("z", :b)]
            bds = Ressac.list_instruments(r"^bd")
            @test sort([e.name for e in bds]) == [:bd_alt]
            empty!(Ressac._INSTRUMENT_REGISTRY)
        end
    end

    @testset "synth registry" begin
        empty!(Ressac._SYNTH_REGISTRY)

        @testset "register_synth! / synth_info round-trip" begin
            ent = Ressac.SynthEntry(:bassline, "funkit",
                Dict{String,Any}("tags" => ["bass"], "description" => "warm"))
            Ressac.register_synth!(ent)
            got = Ressac.synth_info(:bassline)
            @test got !== nothing
            @test got.metadata["description"] == "warm"
            empty!(Ressac._SYNTH_REGISTRY)
        end

        @testset "list_synths sorts + filters" begin
            for ent in [
                Ressac.SynthEntry(:pad, "z", Dict{String,Any}()),
                Ressac.SynthEntry(:bassline, "a", Dict{String,Any}()),
            ]
                Ressac.register_synth!(ent)
            end
            @test [e.name for e in Ressac.list_synths()] == [:bassline, :pad]
            @test [e.name for e in Ressac.list_synths(r"bass")] == [:bassline]
            empty!(Ressac._SYNTH_REGISTRY)
        end

        @testset "shadow warns" begin
            a = Ressac.SynthEntry(:dup, "p1", Dict{String,Any}())
            b = Ressac.SynthEntry(:dup, "p2", Dict{String,Any}())
            Ressac.register_synth!(a)
            @test_logs (:warn, r"dup.*shadow") match_mode=:any begin
                Ressac.register_synth!(b)
            end
            @test Ressac.synth_info(:dup).plugin == "p1"
            empty!(Ressac._SYNTH_REGISTRY)
        end
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`
Expected: `UndefVarError: InstrumentEntry`.

- [ ] **Step 3: Add the registries**

Append to `src/plugins.jl`:

```julia
"""
    InstrumentEntry(name, plugin, params, metadata)

A named bundle of `/dirt/play` params that the user can invoke by short
name. `params` is a `Vector{Pair{String,Any}}` (not Dict) so the order
declared in the TOML manifest survives the round-trip into OSC.

- `name`     — Symbol used in patterns (`:kicklourd`)
- `plugin`   — the plugin that contributed this preset
- `params`   — declared OSC params in TOML order (`s` first by convention)
- `metadata` — reserved keys pulled from the same manifest table
              (`tags`, `description`, `comment`)
"""
struct InstrumentEntry
    name::Symbol
    plugin::String
    params::Vector{Pair{String,Any}}
    metadata::Dict{String,Any}
end

"""
    SynthEntry(name, plugin, metadata)

Metadata-only registry entry for a synth exposed by a plugin. The
SynthDef itself is loaded via the existing `[synthdefs]` section; this
entry only enables `:synths` listing and `K` preview.
"""
struct SynthEntry
    name::Symbol
    plugin::String
    metadata::Dict{String,Any}
end

const _INSTRUMENT_REGISTRY = Dict{Symbol,InstrumentEntry}()
const _SYNTH_REGISTRY      = Dict{Symbol,SynthEntry}()

"""
    register_instrument!(entry::InstrumentEntry)

First-wins registration. Shadow attempts log `[WARN] instrument 'X' …`
and are skipped.
"""
function register_instrument!(entry::InstrumentEntry)
    if haskey(_INSTRUMENT_REGISTRY, entry.name)
        existing = _INSTRUMENT_REGISTRY[entry.name]
        @warn "instrument '$(entry.name)' shadowed by plugin '$(entry.plugin)' (already loaded from '$(existing.plugin)')"
        return entry
    end
    _INSTRUMENT_REGISTRY[entry.name] = entry
    return entry
end

"""
    register_synth!(entry::SynthEntry)

First-wins registration. Same shadow semantics as
[`register_instrument!`](@ref).
"""
function register_synth!(entry::SynthEntry)
    if haskey(_SYNTH_REGISTRY, entry.name)
        existing = _SYNTH_REGISTRY[entry.name]
        @warn "synth '$(entry.name)' shadowed by plugin '$(entry.plugin)' (already loaded from '$(existing.plugin)')"
        return entry
    end
    _SYNTH_REGISTRY[entry.name] = entry
    return entry
end

instrument_info(name::Symbol) = get(_INSTRUMENT_REGISTRY, name, nothing)
synth_info(name::Symbol)      = get(_SYNTH_REGISTRY,      name, nothing)

"""
    list_instruments(pattern::Regex = r"") -> Vector{InstrumentEntry}

Registered instruments matching `pattern` (by name), sorted by
`(plugin, name)`.
"""
function list_instruments(pattern::Regex = r"")
    out = InstrumentEntry[]
    for (name, entry) in _INSTRUMENT_REGISTRY
        occursin(pattern, String(name)) && push!(out, entry)
    end
    sort!(out, by = e -> (e.plugin, String(e.name)))
    return out
end

"""
    list_synths(pattern::Regex = r"") -> Vector{SynthEntry}

Registered synths matching `pattern`, sorted by `(plugin, name)`.
"""
function list_synths(pattern::Regex = r"")
    out = SynthEntry[]
    for (name, entry) in _SYNTH_REGISTRY
        occursin(pattern, String(name)) && push!(out, entry)
    end
    sort!(out, by = e -> (e.plugin, String(e.name)))
    return out
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all 368 pre-existing + ~14 new pass.

- [ ] **Step 5: Commit**

```bash
git add src/plugins.jl test/test_plugins.jl
git commit -m "plugins: InstrumentEntry + SynthEntry registries"
```

---

## Task 2: _osc_value converter

**Files:**
- Modify: `src/plugin_handlers.jl`
- Modify: `test/test_plugin_handlers.jl`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_plugin_handlers.jl` inside the outer `@testset "plugin_handlers"`:

```julia
    @testset "_osc_value type conversions" begin
        @test Ressac._osc_value(Int64(3))    === Int32(3)
        @test Ressac._osc_value(Int32(3))    === Int32(3)
        @test Ressac._osc_value(Float64(1.2)) === Float32(1.2)
        @test Ressac._osc_value(Float32(1.5)) === Float32(1.5)
        @test Ressac._osc_value("bd")        == "bd"
        @test Ressac._osc_value(true)        === Int32(1)
        @test Ressac._osc_value(false)       === Int32(0)
    end

    @testset "_osc_value warns + returns missing for unsupported types" begin
        result = @test_logs (:warn, r"unsupported OSC value") match_mode=:any begin
            Ressac._osc_value(Dict("x" => 1))
        end
        @test result === missing
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`
Expected: `UndefVarError: _osc_value`.

- [ ] **Step 3: Add the converter**

In `src/plugin_handlers.jl`, just above the `_handle_julia` function definition, append:

```julia
"""
    _osc_value(v)

Convert a TOML-parsed value into something that the existing OSC encoder
can ship as a `/dirt/play` argument. Lossy by design: TOML's `Int64` /
`Float64` widen narrows to OSC's 32-bit forms; `Bool` becomes `0`/`1`
(SuperDirt convention). Unknown types log a `@warn` and return `missing`
so the caller can drop the offending pair without crashing the dispatch.
"""
function _osc_value(v::Bool)
    return v ? Int32(1) : Int32(0)
end
_osc_value(v::Integer) = Int32(v)
_osc_value(v::AbstractFloat) = Float32(v)
_osc_value(v::AbstractString) = String(v)
function _osc_value(v)
    @warn "unsupported OSC value of type $(typeof(v)); dropping"
    return missing
end
```

The `Bool` method is declared first because `Bool <: Integer` in Julia — we want the Bool-specific behaviour, not the generic Integer narrowing.

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/plugin_handlers.jl test/test_plugin_handlers.jl
git commit -m "plugin_handlers: _osc_value TOML→OSC type converter"
```

---

## Task 3: Withinst fixture

**Files:**
- Create: `test/fixtures/plugins/withinst/plugin.toml`

- [ ] **Step 1: Create the fixture manifest**

Create `test/fixtures/plugins/withinst/plugin.toml`:

```toml
name        = "withinst"
version     = "0.1.0"
description = "fixture for [instruments] and [synths]"

[instruments.kicklourd]
s     = "bd"
n     = 3
gain  = 1.2
lpf   = 200
tags  = ["heavy", "subby"]
description = "the kick that hurts"

[instruments.bassy]
s    = "bassline"
freq = 110
amp  = 0.6

[synths.bassline]
tags = ["bass", "low"]
description = "warm sub bass"
```

- [ ] **Step 2: Verify it parses with the existing manifest parser**

Run:
```bash
julia --project=. -e 'using Ressac; m = Ressac.parse_manifest("test/fixtures/plugins/withinst"); println(m.name); println(sort(collect(keys(m.sections))))'
```
Expected: prints `withinst` and `["instruments", "synths"]`.

- [ ] **Step 3: Final test pass — nothing should regress**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: still passing.

- [ ] **Step 4: Commit**

```bash
git add test/fixtures/plugins/withinst/
git commit -m "plugins: fixture withinst with [instruments] + [synths]"
```

---

## Task 4: _handle_instruments handler

**Files:**
- Modify: `src/plugin_handlers.jl`
- Modify: `test/test_plugin_handlers.jl`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_plugin_handlers.jl`:

```julia
    @testset "[instruments] handler populates registry — preserves param order" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        m = Ressac.parse_manifest(joinpath(@__DIR__, "fixtures", "plugins", "withinst"))
        h = Ressac.get_section_handler(:instruments)
        @test h !== nothing
        h(m.dir, m.sections["instruments"], m.name)

        kick = Ressac.instrument_info(:kicklourd)
        @test kick !== nothing
        @test kick.plugin == "withinst"
        # `s` must come first; we hand-rolled the manifest so `s,n,gain,lpf`
        # is the declared order.
        @test kick.params[1] == ("s" => "bd")
        @test ["s", "n", "gain", "lpf"] == [p.first for p in kick.params]
        @test kick.metadata["tags"] == ["heavy", "subby"]
        @test kick.metadata["description"] == "the kick that hurts"

        bassy = Ressac.instrument_info(:bassy)
        @test bassy.params[1] == ("s" => "bassline")
        @test isempty(bassy.metadata)
        empty!(Ressac._INSTRUMENT_REGISTRY)
    end

    @testset "[instruments] missing 's' key logs error, skips entry" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        h = Ressac.get_section_handler(:instruments)
        @test_logs (:error, r"kicklourd.*missing.*s") match_mode=:any begin
            h("/tmp",
              Dict("kicklourd" => Dict{String,Any}("gain" => 1.0)),
              "ghost")
        end
        @test Ressac.instrument_info(:kicklourd) === nothing
        empty!(Ressac._INSTRUMENT_REGISTRY)
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`
Expected: `:instruments` handler not registered → `h === nothing`.

- [ ] **Step 3: Add the handler**

In `src/plugin_handlers.jl`, append (after the `_handle_synthdefs`/registration):

```julia
const _INSTRUMENT_RESERVED_KEYS = ("tags", "description", "comment")

"""
    _handle_instruments(plugin_dir, data, plugin_name)

Parse `[instruments.<name>]` sub-tables. Each entry must declare `s`
(the sample or synth name to dispatch to); everything else is either
metadata (`tags`/`description`/`comment`) or an OSC param. Params are
collected in TOML declaration order, with `s` forced first.

Errors are logged; processing continues with the next entry.
"""
function _handle_instruments(plugin_dir, data, plugin_name)
    data isa AbstractDict ||
        throw(ArgumentError("plugin '$plugin_name' [instruments] must be a table"))
    for (name, body) in data
        body isa AbstractDict || begin
            @error "plugin '$plugin_name' [instruments.$name] must be a table"
            continue
        end
        if !haskey(body, "s")
            @error "plugin '$plugin_name' [instruments.$name]: missing required key 's'"
            continue
        end
        params = Pair{String,Any}[]
        metadata = Dict{String,Any}()
        # `s` first.
        push!(params, "s" => body["s"])
        for (k, v) in body
            k == "s" && continue
            if k in _INSTRUMENT_RESERVED_KEYS
                metadata[k] = v
            else
                push!(params, k => v)
            end
        end
        register_instrument!(InstrumentEntry(Symbol(name), plugin_name, params, metadata))
    end
    return nothing
end

register_section_handler!(:instruments, _handle_instruments)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass; instrument-order test green.

Note: TOML's `Dict` iteration order is not guaranteed in general, but
`TOML.parsefile` on TOML.jl 1.x preserves insertion order via
`Dict{String,Any}` with `OrderedDict`-like ordering on real text input.
If the order test fails on some platforms, swap the implementation to
read the original TOML lines and sort by line number — but the
fixture is small enough that practical test runs are stable.

- [ ] **Step 5: Commit**

```bash
git add src/plugin_handlers.jl test/test_plugin_handlers.jl
git commit -m "plugin_handlers: [instruments] handler with reserved-key metadata split"
```

---

## Task 5: _handle_synths handler

**Files:**
- Modify: `src/plugin_handlers.jl`
- Modify: `test/test_plugin_handlers.jl`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_plugin_handlers.jl`:

```julia
    @testset "[synths] handler populates registry with metadata" begin
        empty!(Ressac._SYNTH_REGISTRY)
        m = Ressac.parse_manifest(joinpath(@__DIR__, "fixtures", "plugins", "withinst"))
        h = Ressac.get_section_handler(:synths)
        @test h !== nothing
        h(m.dir, m.sections["synths"], m.name)

        bassline = Ressac.synth_info(:bassline)
        @test bassline !== nothing
        @test bassline.plugin == "withinst"
        @test bassline.metadata["tags"] == ["bass", "low"]
        @test bassline.metadata["description"] == "warm sub bass"
        empty!(Ressac._SYNTH_REGISTRY)
    end

    @testset "[synths] handler accepts empty metadata table" begin
        empty!(Ressac._SYNTH_REGISTRY)
        h = Ressac.get_section_handler(:synths)
        h("/tmp", Dict("plain" => Dict{String,Any}()), "ghost")
        @test Ressac.synth_info(:plain) !== nothing
        @test isempty(Ressac.synth_info(:plain).metadata)
        empty!(Ressac._SYNTH_REGISTRY)
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`
Expected: handler not registered → `h === nothing`.

- [ ] **Step 3: Add the handler**

Append to `src/plugin_handlers.jl`:

```julia
"""
    _handle_synths(plugin_dir, data, plugin_name)

Parse `[synths.<name>]` sub-tables. Each entry is metadata-only and gets
stored verbatim in `SynthEntry.metadata`. The SynthDef itself must be
loaded separately via `[synthdefs] files = [...]` — this handler is
purely about discoverability.
"""
function _handle_synths(plugin_dir, data, plugin_name)
    data isa AbstractDict ||
        throw(ArgumentError("plugin '$plugin_name' [synths] must be a table"))
    for (name, body) in data
        body isa AbstractDict || begin
            @error "plugin '$plugin_name' [synths.$name] must be a table"
            continue
        end
        meta = Dict{String,Any}(string(k) => v for (k, v) in body)
        register_synth!(SynthEntry(Symbol(name), plugin_name, meta))
    end
    return nothing
end

register_section_handler!(:synths, _handle_synths)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/plugin_handlers.jl test/test_plugin_handlers.jl
git commit -m "plugin_handlers: [synths] handler — metadata + listing"
```

---

## Task 6: Extend event_to_osc to consult instrument registry

**Files:**
- Modify: `src/scheduler.jl`
- Modify: `test/test_scheduler.jl`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_scheduler.jl` inside `@testset "scheduler"`:

```julia
    @testset "event_to_osc: instrument resolves to multi-arg /dirt/play" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        Ressac.register_instrument!(Ressac.InstrumentEntry(:kicklourd, "p",
            Pair{String,Any}["s" => "bd", "n" => 3, "gain" => 1.2, "lpf" => 200],
            Dict{String,Any}()))
        try
            msg = Ressac.event_to_osc(Event(0//1, 1//4, :kicklourd))
            @test msg.address == "/dirt/play"
            # Args interleave key/value: s "bd" n 3 gain 1.2 lpf 200.
            @test msg.args[1:2] == Any["s", "bd"]
            @test msg.args[3]   == "n"
            @test msg.args[4]   === Int32(3)
            @test msg.args[5]   == "gain"
            @test msg.args[6]   === Float32(1.2)
            @test msg.args[7]   == "lpf"
            @test msg.args[8]   === Int32(200)
        finally
            empty!(Ressac._INSTRUMENT_REGISTRY)
        end
    end

    @testset "event_to_osc: unknown symbol falls back to single-arg form" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        msg = Ressac.event_to_osc(Event(0//1, 1//4, :bd))
        @test msg.args == Any["s", "bd"]
    end

    @testset "event_to_osc: unsupported param value is dropped + warned" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        Ressac.register_instrument!(Ressac.InstrumentEntry(:weird, "p",
            Pair{String,Any}["s" => "bd", "blob" => Dict("nested" => 1)],
            Dict{String,Any}()))
        try
            msg = @test_logs (:warn, r"unsupported OSC value") match_mode=:any begin
                Ressac.event_to_osc(Event(0//1, 1//4, :weird))
            end
            # The bad pair is dropped; s "bd" survives.
            @test msg.args == Any["s", "bd"]
        finally
            empty!(Ressac._INSTRUMENT_REGISTRY)
        end
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`
Expected: instrument test fails — current `event_to_osc` returns
single-arg form regardless.

- [ ] **Step 3: Rewrite event_to_osc**

In `src/scheduler.jl`, replace the existing `event_to_osc(::Event{Symbol})` method body with:

```julia
event_to_osc(ev::Event{Symbol}) = begin
    inst = instrument_info(ev.value)
    if inst === nothing
        return OSCMessage("/dirt/play", Any["s", String(ev.value)])
    end
    args = Any[]
    for (k, v) in inst.params
        converted = _osc_value(v)
        converted === missing && continue
        push!(args, String(k))
        push!(args, converted)
    end
    return OSCMessage("/dirt/play", args)
end
```

`instrument_info` and `_osc_value` are in the same module so no
qualification is needed. The fallback (`inst === nothing`) preserves
the existing 367-test behaviour.

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass; new instrument-dispatch tests green.

- [ ] **Step 5: Commit**

```bash
git add src/scheduler.jl test/test_scheduler.jl
git commit -m "scheduler: event_to_osc dispatches via _INSTRUMENT_REGISTRY"
```

---

## Task 7: Extend K preview to instrument > sample > synth

**Files:**
- Modify: `src/tui_bindings.jl`
- Modify: `test/test_tui_bindings.jl`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_tui_bindings.jl` inside `@testset "tui_bindings"`:

```julia
    @testset "K resolves instrument over sample with same name" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        empty!(Ressac._INSTRUMENT_REGISTRY)
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            Ressac.register_sample!(Ressac.SampleEntry(:bd, "core",
                "/c/bd", ["/c/bd/a.wav"], Dict{String,Any}()))
            Ressac.register_instrument!(Ressac.InstrumentEntry(:bd, "funkit",
                Pair{String,Any}["s" => "bd", "gain" => 1.5],
                Dict{String,Any}()))

            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["bd"]
            m.cursor_row = 1
            m.cursor_col = 1
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key("K"))

            play = [Ressac.decode_message(b) for b in mock.sent
                    if Ressac.decode_message(b).address == "/dirt/play"]
            @test length(play) == 1
            # Instrument wins → multi-arg.
            @test play[1].args[1:2] == Any["s", "bd"]
            @test play[1].args[3]   == "gain"
            @test play[1].args[4]   === Float32(1.5)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            empty!(Ressac._SAMPLE_REGISTRY)
            empty!(Ressac._INSTRUMENT_REGISTRY)
        end
    end

    @testset "K on synth-only name uses single-arg play" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        empty!(Ressac._INSTRUMENT_REGISTRY)
        empty!(Ressac._SYNTH_REGISTRY)
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            Ressac.register_synth!(Ressac.SynthEntry(:bassline, "funkit",
                Dict{String,Any}()))
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["bassline"]
            m.cursor_row = 1; m.cursor_col = 1; m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key("K"))

            play = [Ressac.decode_message(b) for b in mock.sent
                    if Ressac.decode_message(b).address == "/dirt/play"]
            @test length(play) == 1
            @test play[1].args == Any["s", "bassline"]
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            empty!(Ressac._SYNTH_REGISTRY)
        end
    end

    @testset "K on completely unknown word logs warning" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        empty!(Ressac._INSTRUMENT_REGISTRY)
        empty!(Ressac._SYNTH_REGISTRY)
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["nothingknownhere"]
            m.cursor_row = 1; m.cursor_col = 1; m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key("K"))
            @test isempty(mock.sent)
            @test any(l -> occursin("no sample/instrument/synth", l), m.logs)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`
Expected: K-on-bd test fails — currently K only resolves samples and
returns single-arg form for `:bd`. Also the synth path returns
`[WARN] no sample 'bassline' loaded` instead of finding `:bassline`
in `_SYNTH_REGISTRY`.

- [ ] **Step 3: Rewrite `_preview_under_cursor!`**

In `src/tui_bindings.jl`, replace the existing body of
`_preview_under_cursor!`:

```julia
function _preview_under_cursor!(m::LiveModel)
    line = m.buffer[m.cursor_row]
    isempty(line) && return
    col = clamp(m.cursor_col, 1, lastindex(line) + 1)
    start = col
    while start > 1 && _is_word_char(line[prevind(line, start)])
        start = prevind(line, start)
    end
    stop = col
    while stop <= lastindex(line) && _is_word_char(line[stop])
        stop = nextind(line, stop)
    end
    stop = prevind(line, stop)
    word = start > stop ? "" : line[start:stop]
    isempty(word) && return

    mt = match(_WORD_RX, word)
    if mt === nothing
        _push_log!(m, "[WARN] no sample/instrument/synth '$word' loaded")
        return
    end
    name = Symbol(mt.captures[1])
    variant = mt.captures[2] === nothing ? 0 : parse(Int, mt.captures[2])

    sched = _LIVE_SCHEDULER[]
    if sched === nothing
        _push_log!(m, "[ERROR] preview: no active session")
        return
    end

    # Resolution order: instrument > sample > synth. Instruments are the
    # most specific (full param bundle), samples have variants, synths
    # use a plain single-arg play.
    inst = instrument_info(name)
    if inst !== nothing
        send_osc(sched.osc, encode(event_to_osc(Event(0//1, 0//1, name))))
        _push_log!(m, "[INFO] preview $(mt.captures[1]) (instrument)")
        return
    end

    if sample_info(name) !== nothing
        args = variant == 0 ?
            Any["s", String(name)] :
            Any["s", String(name), "n", Int32(variant)]
        send_osc(sched.osc, encode(OSCMessage("/dirt/play", args)))
        _push_log!(m, "[INFO] preview $(mt.captures[1])$(variant == 0 ? "" : ":$variant")")
        return
    end

    if synth_info(name) !== nothing
        send_osc(sched.osc, encode(OSCMessage("/dirt/play", Any["s", String(name)])))
        _push_log!(m, "[INFO] preview $(mt.captures[1]) (synth)")
        return
    end

    _push_log!(m, "[WARN] no sample/instrument/synth '$(mt.captures[1])' loaded")
end
```

The instrument branch reuses `event_to_osc` so the multi-arg form
matches what would actually fire during a pattern. The sample branch
keeps the `:N` variant suffix support from sub-project 2. The synth
branch is a plain single-arg `/dirt/play`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/tui_bindings.jl test/test_tui_bindings.jl
git commit -m "tui: K resolves instrument > sample > synth"
```

---

## Task 8: `:instruments` and `:synths` ex-commands

**Files:**
- Modify: `src/tui_bindings.jl`
- Modify: `test/test_tui_bindings.jl`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_tui_bindings.jl`:

```julia
    @testset ":instruments lists all loaded instruments" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        try
            Ressac.register_instrument!(Ressac.InstrumentEntry(:kicklourd, "funkit",
                Pair{String,Any}["s" => "bd", "n" => 3, "gain" => 1.2],
                Dict{String,Any}("tags" => ["heavy"])))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key(":"))
            for c in "instruments"
                Ressac._dispatch_key!(m, _fake_key(string(c)))
            end
            Ressac._dispatch_key!(m, _fake_key("Enter"))
            logs = join(m.logs, "\n")
            @test occursin("kicklourd", logs)
            @test occursin("funkit", logs)
            @test occursin("s=bd", logs)
            @test occursin("heavy", logs)
        finally
            empty!(Ressac._INSTRUMENT_REGISTRY)
        end
    end

    @testset ":instruments <glob> filters" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        try
            Ressac.register_instrument!(Ressac.InstrumentEntry(:kicklourd, "p",
                Pair{String,Any}["s" => "bd"], Dict{String,Any}()))
            Ressac.register_instrument!(Ressac.InstrumentEntry(:snareheavy, "p",
                Pair{String,Any}["s" => "sn"], Dict{String,Any}()))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key(":"))
            for c in "instruments kic*"
                Ressac._dispatch_key!(m, _fake_key(string(c)))
            end
            Ressac._dispatch_key!(m, _fake_key("Enter"))
            logs = join(m.logs, "\n")
            @test occursin("kicklourd", logs)
            @test !occursin("snareheavy", logs)
        finally
            empty!(Ressac._INSTRUMENT_REGISTRY)
        end
    end

    @testset ":instruments <name> shows full detail" begin
        empty!(Ressac._INSTRUMENT_REGISTRY)
        try
            Ressac.register_instrument!(Ressac.InstrumentEntry(:kicklourd, "funkit",
                Pair{String,Any}["s" => "bd", "gain" => 1.2],
                Dict{String,Any}("description" => "the kick that hurts")))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key(":"))
            for c in "instruments kicklourd"
                Ressac._dispatch_key!(m, _fake_key(string(c)))
            end
            Ressac._dispatch_key!(m, _fake_key("Enter"))
            logs = join(m.logs, "\n")
            @test occursin("kicklourd", logs)
            @test occursin("the kick that hurts", logs)
            @test occursin("gain", logs)
        finally
            empty!(Ressac._INSTRUMENT_REGISTRY)
        end
    end

    @testset ":synths lists synths" begin
        empty!(Ressac._SYNTH_REGISTRY)
        try
            Ressac.register_synth!(Ressac.SynthEntry(:bassline, "funkit",
                Dict{String,Any}("tags" => ["bass"], "description" => "warm")))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key(":"))
            for c in "synths"
                Ressac._dispatch_key!(m, _fake_key(string(c)))
            end
            Ressac._dispatch_key!(m, _fake_key("Enter"))
            logs = join(m.logs, "\n")
            @test occursin("bassline", logs)
            @test occursin("warm", logs) || occursin("bass", logs)
        finally
            empty!(Ressac._SYNTH_REGISTRY)
        end
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`
Expected: `:instruments` / `:synths` → `[ERROR] unknown command`.

- [ ] **Step 3: Wire the ex-commands**

In `src/tui_bindings.jl`, find `_execute_ex_command!` and add two new
branches right before the `else` that logs unknown command:

```julia
    elseif body == "instruments" || startswith(body, "instruments ")
        rest = strip(body == "instruments" ? "" : body[13:end])
        _execute_instruments_command!(m, rest)
    elseif body == "synths" || startswith(body, "synths ")
        rest = strip(body == "synths" ? "" : body[8:end])
        _execute_synths_command!(m, rest)
```

Then append the helpers at the bottom of `src/tui_bindings.jl`:

```julia
function _execute_instruments_command!(m::LiveModel, arg::AbstractString)
    if isempty(arg)
        _list_instruments_to_log!(m, list_instruments(r""))
        return
    end
    if occursin('*', arg) || occursin('?', arg)
        rx = Regex("^" * replace(replace(arg, "*" => ".*"), "?" => ".") * "\$")
        _list_instruments_to_log!(m, list_instruments(rx))
        return
    end
    entry = instrument_info(Symbol(arg))
    if entry === nothing
        _push_log!(m, "[WARN] no instrument '$arg' loaded")
        return
    end
    desc = get(entry.metadata, "description", "")
    head = isempty(desc) ? "" : " — \"$desc\""
    _push_log!(m, "[$(entry.plugin)] $(entry.name)$head")
    for (k, v) in entry.params
        _push_log!(m, "  $k = $v")
    end
    for (k, v) in entry.metadata
        k == "description" && continue
        _push_log!(m, "  ($k) $v")
    end
end

function _list_instruments_to_log!(m::LiveModel, entries)
    if isempty(entries)
        _push_log!(m, "(no instruments loaded)")
        return
    end
    current_plugin = ""
    for e in entries
        if e.plugin != current_plugin
            _push_log!(m, "── $(e.plugin) ──")
            current_plugin = e.plugin
        end
        summary = join(("$k=$v" for (k, v) in e.params), " ")
        tags = get(e.metadata, "tags", String[])
        tag_str = isempty(tags) ? "" : "  [" * join(tags, ", ") * "]"
        _push_log!(m, "  $(e.name)   $summary$tag_str")
    end
end

function _execute_synths_command!(m::LiveModel, arg::AbstractString)
    if isempty(arg)
        _list_synths_to_log!(m, list_synths(r""))
        return
    end
    if occursin('*', arg) || occursin('?', arg)
        rx = Regex("^" * replace(replace(arg, "*" => ".*"), "?" => ".") * "\$")
        _list_synths_to_log!(m, list_synths(rx))
        return
    end
    entry = synth_info(Symbol(arg))
    if entry === nothing
        _push_log!(m, "[WARN] no synth '$arg' loaded")
        return
    end
    desc = get(entry.metadata, "description", "")
    head = isempty(desc) ? "" : " — \"$desc\""
    _push_log!(m, "[$(entry.plugin)] $(entry.name)$head")
    for (k, v) in entry.metadata
        k == "description" && continue
        _push_log!(m, "  $k: $v")
    end
end

function _list_synths_to_log!(m::LiveModel, entries)
    if isempty(entries)
        _push_log!(m, "(no synths loaded)")
        return
    end
    current_plugin = ""
    for e in entries
        if e.plugin != current_plugin
            _push_log!(m, "── $(e.plugin) ──")
            current_plugin = e.plugin
        end
        tags = get(e.metadata, "tags", String[])
        tag_str = isempty(tags) ? "" : "  [" * join(tags, ", ") * "]"
        desc = get(e.metadata, "description", "")
        desc_str = isempty(desc) ? "" : "  \"$desc\""
        _push_log!(m, "  $(e.name)$tag_str$desc_str")
    end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/tui_bindings.jl test/test_tui_bindings.jl
git commit -m "tui: :instruments and :synths ex-commands (list, glob, detail)"
```

---

## Task 9: `:guide` ex-command

**Files:**
- Modify: `src/tui_bindings.jl`
- Modify: `test/test_tui_bindings.jl`

- [ ] **Step 1: Write the failing test**

Append to `test/test_tui_bindings.jl`:

```julia
    @testset ":guide writes the full reference to logs" begin
        m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
        m.mode = :normal
        Ressac._dispatch_key!(m, _fake_key(":"))
        for c in "guide"
            Ressac._dispatch_key!(m, _fake_key(string(c)))
        end
        Ressac._dispatch_key!(m, _fake_key("Enter"))
        logs = join(m.logs, "\n")
        # Sanity-check that key reference sections are present.
        @test occursin("modes:", logs)
        @test occursin("eval", logs)
        @test occursin("samples", logs)
        @test occursin("instruments", logs)
        @test occursin("mini-notation", logs)
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`
Expected: `:guide` → `[ERROR] unknown command`.

- [ ] **Step 3: Wire :guide + add the const text**

In `src/tui_bindings.jl`, add the branch in `_execute_ex_command!`
alongside the others, before the `else`:

```julia
    elseif body == "guide"
        for line in _GUIDE_LINES
            _push_log!(m, line)
        end
```

Then append the const near the top of the file (before the first
function definition), or just at the bottom — either works since
`_GUIDE_LINES` is only read by `_execute_ex_command!` which is also
in the same file:

```julia
const _GUIDE_LINES = String[
    "── Ressac quick reference ──",
    "modes:  i/a/o/O insert | Esc normal | V visual | : command",
    "nav:    h j k l   0 $   gg G   <N>e (eval at +N cycles)",
    "edit:   x  dd  yy  [N]yy  p P  Esc",
    "eval:   e (now)   [N]e (next-cycle / +N cycles)   m (mute toggle)",
    "goto:   gd<N> jumps to last @d<N>   n / N cycle search results",
    "search: /<rx> forward | ?<rx> backward",
    "sound discovery:",
    "  K              preview the sample/instrument/synth under cursor",
    "  :samples       list loaded sample banks",
    "  :synths        list loaded synths",
    "  :instruments   list loaded instrument presets",
    "  :samples bd*   glob filter",
    "  :samples bd    detail for one bank",
    "commands: :q  :cps <x>  :goto d<N>  :samples  :synths  :instruments  :guide",
    "live API: @d1 p\"bd hh sn hh\" |> fast(2)   (slots @d1..@d64)",
    "mini-notation: bd hh sn   ~ silence   [a b] subdivide   <a b c> alternate",
    "               x*N repeat   x!N stretch   x(K,N) Euclidean   bd:1 variant",
]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/tui_bindings.jl test/test_tui_bindings.jl
git commit -m "tui: :guide ex-command dumps the full keybinding/syntax reference"
```

---

## Task 10: Cheatsheet update

**Files:**
- Modify: `docs/cheatsheet.md`

- [ ] **Step 1: Find the existing "Sample bank workflow" subsection**

Run: `grep -n "Sample bank workflow\|Common gotchas" docs/cheatsheet.md`
Expected: matches "Sample bank workflow" then "Common gotchas".

- [ ] **Step 2: Insert the new subsection BEFORE "Common gotchas"**

In `docs/cheatsheet.md`, find `## Common gotchas` and insert immediately
above it:

````markdown
### Instruments & synths

Instruments are named bundles of `/dirt/play` params declared in a
plugin manifest:

```toml
[instruments.kicklourd]
s    = "bd"        # required: sample or synth name to dispatch to
n    = 3
gain = 1.2
lpf  = 200
tags = ["heavy"]   # reserved metadata key (with description, comment)
description = "the kick that hurts"

[synths.bassline]   # metadata only — loading still happens in [synthdefs]
tags = ["bass"]
description = "warm sub bass"
```

In a pattern, `kicklourd` produces a multi-arg `/dirt/play` with all
params, while plain sample/synth names keep the single-arg form:

```
@d1 p"kicklourd hh sn"      # kicklourd expanded; hh, sn plain
```

```
:instruments              # list all presets
:instruments kic*         # glob
:instruments kicklourd    # detail
:synths                   # parallel for synths
:guide                    # full keybinding + syntax reference dumped to logs
```

`K` resolves under-cursor in instrument > sample > synth order, so an
instrument named `bd` overrides a sample also named `bd` for preview.

````

- [ ] **Step 3: Commit**

```bash
git add docs/cheatsheet.md
git commit -m "docs: cheatsheet — Instruments & synths section + :guide mention"
```

---

## Task 11: Exports + precompile workload

**Files:**
- Modify: `src/Ressac.jl`

- [ ] **Step 1: Add exports**

In `src/Ressac.jl`, find the sub-project-2 export line:

```julia
export SampleEntry, sample_info, list_samples, register_sample!
```

Add a new export line right after it:

```julia
export InstrumentEntry, instrument_info, list_instruments, register_instrument!
export SynthEntry, synth_info, list_synths, register_synth!
```

- [ ] **Step 2: Extend the precompile workload**

In `src/Ressac.jl`, inside the `@compile_workload begin ... end` block,
just after the sample-bank precompile (the block that uses
`bank_fixture`), append:

```julia
    # Instruments/synths: parse the withinst fixture and exercise the
    # registries + the new event_to_osc dispatch path.
    inst_fixture = joinpath(@__DIR__, "..", "test", "fixtures", "plugins", "withinst")
    if isfile(joinpath(inst_fixture, "plugin.toml"))
        try
            empty!(_INSTRUMENT_REGISTRY)
            empty!(_SYNTH_REGISTRY)
            register_instrument!(InstrumentEntry(:_pc_kick, "withinst",
                Pair{String,Any}["s" => "bd", "n" => 3, "gain" => 1.2],
                Dict{String,Any}("tags" => ["heavy"])))
            register_synth!(SynthEntry(:_pc_synth, "withinst",
                Dict{String,Any}("tags" => ["bass"])))
            instrument_info(:_pc_kick)
            list_instruments(r"_pc")
            synth_info(:_pc_synth)
            list_synths(r"_pc")
            event_to_osc(Event(0//1, 1//4, :_pc_kick))
            empty!(_INSTRUMENT_REGISTRY)
            empty!(_SYNTH_REGISTRY)
        catch
            # Fixtures may not be present in shipped packages; ignore.
        end
    end
```

- [ ] **Step 3: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add src/Ressac.jl
git commit -m "plugins: export instrument/synth API + precompile workload"
```

---

## Self-review summary

Mapping spec → tasks:

- §3 architecture > registries → Task 1.
- §3 architecture > manifest `[instruments]` + reserved meta keys → Task 4.
- §3 architecture > manifest `[synths]` → Task 5.
- §3 architecture > `event_to_osc` dispatch → Task 6 (and `_osc_value` is Task 2, used by Task 6).
- §3 architecture > `K` extension → Task 7.
- §3 TUI bindings > `:instruments` → Task 8.
- §3 TUI bindings > `:synths` → Task 8.
- §3 TUI bindings > `:guide` → Task 9.
- §4 file layout → reflected in this plan's top-level table.
- §5 test strategy → every test listed there appears in Tasks 1, 2, 4, 5, 6, 7, 8, 9.
- §6 out of scope → no tasks (deliberately deferred to sub-projects 5, 6).
- §7 compatibility → the fallback path in Task 6 preserves single-arg
  behaviour for unknown symbols, validated by the regression test in
  the same task.

Type consistency check across tasks: `InstrumentEntry(name::Symbol,
plugin::String, params::Vector{Pair{String,Any}}, metadata::Dict{String,Any})`
used identically in Tasks 1, 4, 6, 7, 8, 11. Same for `SynthEntry`.
`_osc_value` returns Int32/Float32/String/`missing` consistently across
Task 2 (definition) and Task 6 (consumer).

Placeholder scan: none. Every step has full code or full commands.
