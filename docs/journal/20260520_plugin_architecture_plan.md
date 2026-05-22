# Plugin Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the extensible plugin loader for Ressac per spec `docs/journal/20260520_plugin_architecture_design.md` — section-handler registry, search-path discovery, manifest parsing, topological load ordering, and the three built-in handlers (`[samples]`, `[synthdefs]`, `[julia]`).

**Architecture:** Two new src files (`plugins.jl` for registry + loader, `plugin_handlers.jl` for built-in handlers) wired into `Ressac.jl`. Loader runs after `start!(sched)` in `start_live!`, walks the path, parses manifests, runs handlers under try/catch. SuperDirt-side OSCdefs added to `scripts/superdirt-startup.scd` to receive sample-load and synthdef-eval messages.

**Tech Stack:** Julia 1.10+, TOML stdlib, Test stdlib, OSC over UDP (via existing `OSCClient`), Sockets stdlib (already in deps).

---

## File structure

| File | Status | Responsibility |
|---|---|---|
| `Project.toml` | extend | Add `TOML` stdlib to `[deps]`. |
| `src/plugins.jl` | **new** | `register_section_handler!`, `_SECTION_HANDLERS`, manifest parsing, search-path walking, topological sort, `_load_plugins()` orchestrator. |
| `src/plugin_handlers.jl` | **new** | Built-in handlers for `:samples`, `:synthdefs`, `:julia`. Registers them at module load time. |
| `src/Ressac.jl` | extend | Include both new files; export `register_section_handler!`, `load_plugin`; call `_load_plugins()` from `start_live!`. |
| `src/tui.jl` | extend | Add `plugins::Bool = true` kwarg to `start_live!`. |
| `scripts/superdirt-startup.scd` | extend | Add OSCdefs for `/dirt/loadSampleFolder` and `/dirt/evalSC`. |
| `test/test_plugins.jl` | **new** | Registry, manifest parsing, search-path, topo-sort, loader end-to-end. |
| `test/test_plugin_handlers.jl` | **new** | Handler unit tests using MockOSCClient + `_LIVE_SCHEDULER[]` injection. |
| `test/fixtures/plugins/` | **new** | Hand-rolled fixture plugin trees for loader tests. |
| `test/runtests.jl` | extend | Include both new test files. |
| `docs/cheatsheet.md` | extend | New "Plugins" section. |

---

## Task 1: Add TOML to deps + create empty plugin files

**Files:**
- Modify: `Project.toml`
- Create: `src/plugins.jl`
- Create: `src/plugin_handlers.jl`
- Modify: `src/Ressac.jl`

- [ ] **Step 1: Add TOML to deps**

In `Project.toml`, inside `[deps]`, add (in alphabetical order — TOML comes after Sockets):

```toml
TOML = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
```

Run `julia --project=. -e 'using Pkg; Pkg.resolve(); Pkg.instantiate()'` to update the Manifest.

- [ ] **Step 2: Create empty src/plugins.jl**

```julia
# Plugin registry, manifest parsing, search-path discovery, and load
# orchestration. Built-in section handlers live in `plugin_handlers.jl`
# and register themselves through the public API defined here.

using TOML
```

- [ ] **Step 3: Create empty src/plugin_handlers.jl**

```julia
# Built-in section handlers for `[samples]`, `[synthdefs]`, `[julia]`.
# Each is registered at module load time via `register_section_handler!`
# so external plugins use the exact same extension mechanism.
```

- [ ] **Step 4: Include both files from Ressac.jl**

In `src/Ressac.jl`, after the existing `include("live_api.jl")` line (line 24), add:

```julia
include("plugins.jl")
include("plugin_handlers.jl")
```

- [ ] **Step 5: Verify the package still loads + tests pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: `264 passed`.

- [ ] **Step 6: Commit**

```bash
git add Project.toml Manifest.toml src/plugins.jl src/plugin_handlers.jl src/Ressac.jl
git commit -m "plugins: scaffold (TOML dep + empty plugins.jl/plugin_handlers.jl)"
```

---

## Task 2: Section handler registry

**Files:**
- Modify: `src/plugins.jl`
- Create: `test/test_plugins.jl`
- Modify: `test/runtests.jl`

- [ ] **Step 1: Write the failing tests**

Create `test/test_plugins.jl`:

```julia
using Test
using Ressac

@testset "plugins" begin
    @testset "section handler registry" begin
        @testset "register + get round-trip" begin
            seen = Ref{Any}(nothing)
            h = (dir, data, name) -> (seen[] = (dir, data, name); nothing)
            Ressac.register_section_handler!(:_test_section, h)
            @test Ressac.get_section_handler(:_test_section) === h
            # Calling it should populate `seen`.
            h("/tmp", Dict("k" => "v"), "myplugin")
            @test seen[] == ("/tmp", Dict("k" => "v"), "myplugin")
            # Clean up.
            Ressac.unregister_section_handler!(:_test_section)
            @test Ressac.get_section_handler(:_test_section) === nothing
        end

        @testset "overwriting an existing handler logs a warning" begin
            h1 = (a, b, c) -> nothing
            h2 = (a, b, c) -> nothing
            Ressac.register_section_handler!(:_test_overwrite, h1)
            # Capture the @warn output via Test's @test_logs.
            @test_logs (:warn, r"_test_overwrite") begin
                Ressac.register_section_handler!(:_test_overwrite, h2)
            end
            @test Ressac.get_section_handler(:_test_overwrite) === h2
            Ressac.unregister_section_handler!(:_test_overwrite)
        end

        @testset "get returns nothing for unknown section" begin
            @test Ressac.get_section_handler(:_does_not_exist) === nothing
        end
    end
end
```

Add to `test/runtests.jl` before the closing `end`:

```julia
    include("test_plugins.jl")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -8`
Expected: `UndefVarError: register_section_handler!`.

- [ ] **Step 3: Write the registry**

Append to `src/plugins.jl`:

```julia
"""
    _SECTION_HANDLERS

Map from section name (`Symbol`) to handler function. Handler signature:
`(plugin_dir::AbstractString, section_data, plugin_name::AbstractString) -> Nothing`.
"""
const _SECTION_HANDLERS = Dict{Symbol,Function}()

"""
    register_section_handler!(section::Symbol, handler::Function)

Register `handler` to process manifest `[<section>]` blocks. Overwriting an
existing entry logs a warning but is allowed (so plugins can deliberately
replace built-in handlers). Returns the handler.
"""
function register_section_handler!(section::Symbol, handler::Function)
    if haskey(_SECTION_HANDLERS, section)
        @warn "overwriting existing handler for section :$section"
    end
    _SECTION_HANDLERS[section] = handler
    return handler
end

"""
    unregister_section_handler!(section::Symbol)

Drop the handler for `section`. No-op if absent.
"""
function unregister_section_handler!(section::Symbol)
    delete!(_SECTION_HANDLERS, section)
    return nothing
end

"""
    get_section_handler(section::Symbol) -> Union{Function,Nothing}
"""
get_section_handler(section::Symbol) = get(_SECTION_HANDLERS, section, nothing)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass; count goes 264 → 268 (3 new testsets, ~7 assertions).

- [ ] **Step 5: Commit**

```bash
git add src/plugins.jl test/test_plugins.jl test/runtests.jl
git commit -m "plugins: section handler registry (register/unregister/get)"
```

---

## Task 3: Manifest parsing + validation

**Files:**
- Modify: `src/plugins.jl`
- Modify: `test/test_plugins.jl`
- Create: `test/fixtures/plugins/foo/plugin.toml`
- Create: `test/fixtures/plugins/bad-name/plugin.toml`
- Create: `test/fixtures/plugins/no-manifest/`

- [ ] **Step 1: Create fixture plugin manifests**

Create `test/fixtures/plugins/foo/plugin.toml`:

```toml
name        = "foo"
version     = "0.1.0"
description = "fixture plugin used in plugin loader tests"

[samples]
roots = ["./samples"]
```

Create `test/fixtures/plugins/bad-name/plugin.toml`:

```toml
name        = "wrong-name"
version     = "0.1.0"
description = "name doesn't match the directory — this plugin is invalid"
```

Create `test/fixtures/plugins/no-manifest/.gitkeep` (so the empty dir is committed):

```bash
mkdir -p test/fixtures/plugins/no-manifest
touch test/fixtures/plugins/no-manifest/.gitkeep
```

- [ ] **Step 2: Write the failing tests**

Append to `test/test_plugins.jl` inside the outer `@testset "plugins"`:

```julia
    @testset "manifest parsing" begin
        fixtures = joinpath(@__DIR__, "fixtures", "plugins")

        @testset "valid manifest returns name/version/description + sections" begin
            m = Ressac.parse_manifest(joinpath(fixtures, "foo"))
            @test m.name == "foo"
            @test m.version == "0.1.0"
            @test m.description == "fixture plugin used in plugin loader tests"
            @test m.dir == joinpath(fixtures, "foo")
            @test haskey(m.sections, "samples")
            @test m.sections["samples"]["roots"] == ["./samples"]
        end

        @testset "name mismatch throws ArgumentError" begin
            @test_throws ArgumentError Ressac.parse_manifest(
                joinpath(fixtures, "bad-name"))
        end

        @testset "missing plugin.toml throws ArgumentError" begin
            @test_throws ArgumentError Ressac.parse_manifest(
                joinpath(fixtures, "no-manifest"))
        end
    end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -8`
Expected: `UndefVarError: parse_manifest`.

- [ ] **Step 4: Write the parser**

Append to `src/plugins.jl`:

```julia
"""
    PluginManifest

Parsed plugin manifest. `sections` holds every non-meta TOML key — built-in
handlers know about `samples`, `synthdefs`, `julia`; third-party handlers
can register for anything else.
"""
struct PluginManifest
    name::String
    version::String
    description::String
    dir::String
    sections::Dict{String,Any}
    depends_on::Vector{String}
end

const _REQUIRED_META = ("name", "version", "description")

"""
    parse_manifest(plugin_dir) -> PluginManifest

Read `<plugin_dir>/plugin.toml`, validate the required meta keys, check
`name` matches the directory's basename. Anything not in
`("name", "version", "description", "depends_on")` is bundled into
`sections`.

Throws `ArgumentError` for missing manifest, missing required keys, or
name/dirname mismatch.
"""
function parse_manifest(plugin_dir::AbstractString)
    manifest_path = joinpath(plugin_dir, "plugin.toml")
    isfile(manifest_path) ||
        throw(ArgumentError("no plugin.toml at $manifest_path"))
    raw = TOML.parsefile(manifest_path)
    for key in _REQUIRED_META
        haskey(raw, key) ||
            throw(ArgumentError("plugin.toml at $manifest_path missing required key '$key'"))
    end
    expected_name = basename(rstrip(plugin_dir, '/'))
    raw["name"] == expected_name ||
        throw(ArgumentError("plugin.toml name '$(raw["name"])' does not match directory '$expected_name'"))
    depends_on = get(raw, "depends_on", String[])
    depends_on isa AbstractVector ||
        throw(ArgumentError("plugin '$(raw["name"])' depends_on must be an array"))
    sections = Dict{String,Any}()
    for (k, v) in raw
        k in _REQUIRED_META && continue
        k == "depends_on" && continue
        sections[k] = v
    end
    return PluginManifest(
        raw["name"], raw["version"], raw["description"],
        plugin_dir, sections, String.(depends_on),
    )
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src/plugins.jl test/test_plugins.jl test/fixtures/
git commit -m "plugins: parse_manifest + PluginManifest struct"
```

---

## Task 4: Search-path resolution

**Files:**
- Modify: `src/plugins.jl`
- Modify: `test/test_plugins.jl`
- Create: `test/fixtures/plugins-alt/foo/plugin.toml`

- [ ] **Step 1: Create alt-search-path fixture**

Create `test/fixtures/plugins-alt/foo/plugin.toml` — same name as the one in `plugins/foo/` so we can test first-hit-wins:

```toml
name        = "foo"
version     = "9.9.9"
description = "should NOT be loaded — primary search path wins"
```

- [ ] **Step 2: Write the failing tests**

Append to `test/test_plugins.jl`:

```julia
    @testset "search path resolution" begin
        fixtures      = joinpath(@__DIR__, "fixtures", "plugins")
        fixtures_alt  = joinpath(@__DIR__, "fixtures", "plugins-alt")

        @testset "discovers plugins in a single path" begin
            found = Ressac.discover_plugins([fixtures])
            names = sort([m.name for m in found])
            # `foo` has a manifest; `bad-name` has a manifest (it'll fail
            # later in load); `no-manifest` has no manifest, so it's
            # skipped silently.
            @test "foo" in names
            @test "wrong-name" in names || "bad-name" in names  # see below
        end

        @testset "skips directories without plugin.toml" begin
            found = Ressac.discover_plugins([fixtures])
            @test !any(m -> m.name == "no-manifest", found)
        end

        @testset "first hit wins on a multi-path search" begin
            found = Ressac.discover_plugins([fixtures, fixtures_alt])
            foo = only(filter(m -> m.name == "foo", found))
            @test foo.version == "0.1.0"  # NOT 9.9.9 from fixtures-alt
        end

        @testset "reverse order: alt-then-primary picks alt" begin
            found = Ressac.discover_plugins([fixtures_alt, fixtures])
            foo = only(filter(m -> m.name == "foo", found))
            @test foo.version == "9.9.9"
        end

        @testset "non-existent path is silently skipped" begin
            found = Ressac.discover_plugins(["/no/such/path", fixtures])
            @test any(m -> m.name == "foo", found)
        end
    end
```

Note: `discover_plugins` calls `parse_manifest` per directory. The `bad-name` fixture will throw an ArgumentError during parsing — but for *discovery* we want to defer that error and still surface the plugin. We'll have discovery catch parse errors and produce a sentinel + a logged warning. Adjust the test expectations accordingly — `discover_plugins` should NOT throw on bad-name; the loader (Task 6) handles the error.

Refine the test:

```julia
    @testset "search path resolution" begin
        fixtures      = joinpath(@__DIR__, "fixtures", "plugins")
        fixtures_alt  = joinpath(@__DIR__, "fixtures", "plugins-alt")

        @testset "discovers good plugins; bad ones logged but excluded" begin
            results = @test_logs (:warn, r"bad-name") match_mode=:any begin
                Ressac.discover_plugins([fixtures])
            end
            names = [m.name for m in results]
            @test "foo" in names
            @test !("wrong-name" in names)
            @test !("no-manifest" in names)
        end

        @testset "first hit wins on a multi-path search" begin
            found = Ressac.discover_plugins([fixtures, fixtures_alt])
            foo = only(filter(m -> m.name == "foo", found))
            @test foo.version == "0.1.0"
        end

        @testset "reverse order: alt-then-primary picks alt" begin
            found = Ressac.discover_plugins([fixtures_alt, fixtures])
            foo = only(filter(m -> m.name == "foo", found))
            @test foo.version == "9.9.9"
        end

        @testset "non-existent path is silently skipped" begin
            found = Ressac.discover_plugins(["/no/such/path", fixtures])
            @test any(m -> m.name == "foo", found)
        end
    end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -8`
Expected: `UndefVarError: discover_plugins`.

- [ ] **Step 4: Write discover_plugins**

Append to `src/plugins.jl`:

```julia
"""
    discover_plugins(path::Vector{<:AbstractString}) -> Vector{PluginManifest}

Walk each directory in `path` (in order), looking for subdirectories
that contain a `plugin.toml`. Returns parsed manifests. First-hit-wins
per plugin name: if `foo` is found in path[1] AND path[2], path[1]'s
version is kept and a `[WARN] plugin 'foo' shadowed by ...` is logged.

Parse errors on individual manifests are caught and logged at
`@warn` level; the plugin is excluded from the result.

Non-existent or non-directory entries in `path` are silently skipped.
"""
function discover_plugins(path::AbstractVector{<:AbstractString})
    results = PluginManifest[]
    seen = Dict{String,String}()  # name → path of first hit
    for root in path
        isdir(root) || continue
        for entry in readdir(root; join=false)
            plugin_dir = joinpath(root, entry)
            isdir(plugin_dir) || continue
            isfile(joinpath(plugin_dir, "plugin.toml")) || continue
            local m
            try
                m = parse_manifest(plugin_dir)
            catch err
                @warn "skipping plugin at $plugin_dir: $(sprint(showerror, err))"
                continue
            end
            if haskey(seen, m.name)
                @warn "plugin '$(m.name)' shadowed by $plugin_dir (already loaded from $(seen[m.name]))"
                continue
            end
            seen[m.name] = m.dir
            push!(results, m)
        end
    end
    return results
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src/plugins.jl test/test_plugins.jl test/fixtures/plugins-alt/
git commit -m "plugins: discover_plugins walks search path with first-hit-wins"
```

---

## Task 5: Topological sort by depends_on

**Files:**
- Modify: `src/plugins.jl`
- Modify: `test/test_plugins.jl`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_plugins.jl`:

```julia
    @testset "topological sort" begin
        # Helper to build minimal PluginManifest objects for sort tests.
        mk(name, deps=String[]) = Ressac.PluginManifest(
            name, "0.0.0", "test", "/fake/$name", Dict{String,Any}(), deps)

        @testset "no dependencies → stable order" begin
            ms = [mk("a"), mk("b"), mk("c")]
            sorted = Ressac.topo_sort(ms)
            @test [m.name for m in sorted] == ["a", "b", "c"]
        end

        @testset "respects depends_on" begin
            ms = [mk("c", ["a"]), mk("a"), mk("b", ["a"])]
            sorted = Ressac.topo_sort(ms)
            names = [m.name for m in sorted]
            @test findfirst(==("a"), names) < findfirst(==("c"), names)
            @test findfirst(==("a"), names) < findfirst(==("b"), names)
        end

        @testset "missing dep is logged and the plugin is skipped" begin
            ms = [mk("needs-ghost", ["ghost"])]
            sorted = @test_logs (:warn, r"ghost") match_mode=:any begin
                Ressac.topo_sort(ms)
            end
            @test isempty(sorted)
        end

        @testset "cycle is detected and breaks the cycle (both skipped)" begin
            ms = [mk("a", ["b"]), mk("b", ["a"])]
            sorted = @test_logs (:warn, r"cycle") match_mode=:any begin
                Ressac.topo_sort(ms)
            end
            @test isempty(sorted)
        end
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -8`
Expected: `UndefVarError: topo_sort`.

- [ ] **Step 3: Write the sort**

Append to `src/plugins.jl`:

```julia
"""
    topo_sort(manifests::Vector{PluginManifest}) -> Vector{PluginManifest}

Kahn's algorithm with stable secondary order: among plugins with no
remaining deps, pick the one that appeared first in `manifests`.

Plugins that reference a missing dep are logged and dropped. If a
cycle is detected, every plugin still in the cycle is logged and
dropped.
"""
function topo_sort(manifests::AbstractVector{PluginManifest})
    by_name = Dict{String,PluginManifest}()
    for m in manifests
        by_name[m.name] = m
    end
    # Validate all deps exist; drop plugins whose deps are missing.
    valid = PluginManifest[]
    for m in manifests
        missing_deps = [d for d in m.depends_on if !haskey(by_name, d)]
        if !isempty(missing_deps)
            @warn "plugin '$(m.name)' references missing dep(s) $(missing_deps); skipping"
            continue
        end
        push!(valid, m)
    end
    by_name = Dict(m.name => m for m in valid)
    # Kahn's algorithm.
    remaining_deps = Dict(m.name => Set{String}(filter(d -> haskey(by_name, d), m.depends_on)) for m in valid)
    out = PluginManifest[]
    # Original order index for stable tie-break.
    order = Dict(m.name => i for (i, m) in enumerate(valid))
    while !isempty(remaining_deps)
        # Find all plugins with no remaining deps, in original order.
        ready = sort([n for (n, ds) in remaining_deps if isempty(ds)];
                     by = n -> order[n])
        if isempty(ready)
            @warn "plugin dependency cycle detected involving: $(sort(collect(keys(remaining_deps)))); skipping"
            break
        end
        for name in ready
            push!(out, by_name[name])
            delete!(remaining_deps, name)
            for (_, ds) in remaining_deps
                delete!(ds, name)
            end
        end
    end
    return out
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/plugins.jl test/test_plugins.jl
git commit -m "plugins: topo_sort manifests by depends_on (Kahn's, stable, cycle-safe)"
```

---

## Task 6: load_plugin orchestrator

**Files:**
- Modify: `src/plugins.jl`
- Modify: `test/test_plugins.jl`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_plugins.jl`:

```julia
    @testset "load_plugin orchestrator" begin
        # Use a dummy handler that records every call.
        @testset "calls each section's handler with (dir, data, name)" begin
            calls = Tuple[]
            handler = (dir, data, name) -> push!(calls, (Symbol("samples"), dir, data, name))
            Ressac.register_section_handler!(:samples, handler)
            try
                m = Ressac.parse_manifest(joinpath(@__DIR__, "fixtures", "plugins", "foo"))
                Ressac.load_plugin(m)
                @test length(calls) == 1
                _, dir, data, name = calls[1]
                @test name == "foo"
                @test data == Dict("roots" => ["./samples"])
                @test endswith(dir, "/foo")
            finally
                Ressac.unregister_section_handler!(:samples)
            end
        end

        @testset "unknown section logs warning, does not throw" begin
            # Build a manifest with a section that has no handler.
            m = Ressac.PluginManifest(
                "ghost", "0", "x", "/fake/ghost",
                Dict("ghostly" => Dict("k" => "v")), String[])
            @test_logs (:warn, r"ghostly") match_mode=:any begin
                Ressac.load_plugin(m)
            end
        end

        @testset "handler exception is caught and logged" begin
            Ressac.register_section_handler!(:boom, (_, _, _) -> error("kaboom"))
            try
                m = Ressac.PluginManifest(
                    "boomy", "0", "x", "/fake/boomy",
                    Dict("boom" => Dict()), String[])
                @test_logs (:error, r"kaboom") match_mode=:any begin
                    Ressac.load_plugin(m)
                end
            finally
                Ressac.unregister_section_handler!(:boom)
            end
        end

        @testset "[julia] runs before other sections of the same plugin" begin
            seen_order = Symbol[]
            Ressac.register_section_handler!(:julia, (_, _, _) -> push!(seen_order, :julia))
            Ressac.register_section_handler!(:samples, (_, _, _) -> push!(seen_order, :samples))
            try
                m = Ressac.PluginManifest(
                    "order", "0", "x", "/fake/order",
                    Dict("samples" => Dict(), "julia" => Dict("files" => String[])),
                    String[])
                Ressac.load_plugin(m)
                @test seen_order == [:julia, :samples]
            finally
                Ressac.unregister_section_handler!(:julia)
                Ressac.unregister_section_handler!(:samples)
            end
        end
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -8`
Expected: `UndefVarError: load_plugin`.

- [ ] **Step 3: Write load_plugin**

Append to `src/plugins.jl`:

```julia
"""
    load_plugin(manifest::PluginManifest)

Run each section's handler from `manifest.sections`. The `[julia]`
section, if present, runs first inside this plugin (so any
`register_section_handler!` calls it makes are visible to subsequent
sections of the same plugin).

Unknown sections log a warning. Handler exceptions are caught and
logged at `@error` level; the next section still runs.
"""
function load_plugin(m::PluginManifest)
    section_names = collect(keys(m.sections))
    # `julia` runs first if present; rest in their natural Dict order.
    if "julia" in section_names
        section_names = vcat("julia", filter(!=("julia"), section_names))
    end
    for sec_str in section_names
        sec = Symbol(sec_str)
        h = get_section_handler(sec)
        if h === nothing
            @warn "no handler registered for section ':$sec_str' (in plugin '$(m.name)'); skipping"
            continue
        end
        try
            h(m.dir, m.sections[sec_str], m.name)
        catch err
            @error "handler ':$sec_str' for plugin '$(m.name)' raised: $(sprint(showerror, err))"
        end
    end
    return nothing
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/plugins.jl test/test_plugins.jl
git commit -m "plugins: load_plugin runs handlers, [julia] first, catches errors"
```

---

## Task 7: _load_plugins() entry + start_live! integration

**Files:**
- Modify: `src/plugins.jl`
- Modify: `src/tui.jl`
- Modify: `test/test_plugins.jl`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_plugins.jl`:

```julia
    @testset "_load_plugins entry" begin
        fixtures = joinpath(@__DIR__, "fixtures", "plugins")

        @testset "default_plugin_path includes cwd, home, env" begin
            withenv("RESSAC_PLUGIN_PATH" => "/x:/y") do
                p = Ressac.default_plugin_path()
                @test p[1] == joinpath(pwd(), "plugins")
                @test "/x" in p
                @test "/y" in p
            end
        end

        @testset "_load_plugins with custom path discovers + loads" begin
            calls = String[]
            Ressac.register_section_handler!(:samples, (_, _, name) -> push!(calls, name))
            try
                Ressac._load_plugins([fixtures])
                @test "foo" in calls
            finally
                Ressac.unregister_section_handler!(:samples)
            end
        end

        @testset "start_live!(plugins=false) skips loading" begin
            calls = String[]
            Ressac.register_section_handler!(:samples, (_, _, name) -> push!(calls, name))
            try
                mock = MockOSCClient()  # from test_scheduler.jl
                # Use a custom path that contains `foo` but we expect plugins=false to skip it.
                # Inject path via env var for the duration of the test.
                withenv("RESSAC_PLUGIN_PATH" => fixtures) do
                    # Pre-clear any session.
                    Ressac._LIVE_SCHEDULER[] = nothing
                    sched = start_live!(plugins=false)
                    try
                        @test isempty(calls)
                    finally
                        stop_live!()
                    end
                end
            finally
                Ressac.unregister_section_handler!(:samples)
            end
        end
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -8`
Expected: `UndefVarError: default_plugin_path` and `_load_plugins`.

- [ ] **Step 3: Write default_plugin_path + _load_plugins**

Append to `src/plugins.jl`:

```julia
"""
    default_plugin_path() -> Vector{String}

Plugin search path used by default at session start. Order:
1. `\$PWD/plugins`
2. `~/.config/ressac/plugins`
3. Entries from `\$RESSAC_PLUGIN_PATH` (`:`-separated).

Non-existent entries are kept in the list and silently skipped by
`discover_plugins`.
"""
function default_plugin_path()
    path = String[joinpath(pwd(), "plugins")]
    push!(path, joinpath(homedir(), ".config", "ressac", "plugins"))
    extra = get(ENV, "RESSAC_PLUGIN_PATH", "")
    if !isempty(extra)
        for entry in split(extra, ':')
            isempty(entry) || push!(path, String(entry))
        end
    end
    return path
end

"""
    _load_plugins(path = default_plugin_path())

Discover, topo-sort, and load every plugin on the search `path`. Used
internally by `start_live!`; exposed for tests.
"""
function _load_plugins(path::AbstractVector{<:AbstractString} = default_plugin_path())
    manifests = discover_plugins(path)
    ordered = topo_sort(manifests)
    for m in ordered
        try
            load_plugin(m)
            @info "loaded plugin: $(m.name) $(m.version)"
        catch err
            @error "plugin '$(m.name)' failed to load: $(sprint(showerror, err))"
        end
    end
    return nothing
end
```

- [ ] **Step 4: Wire into start_live!**

In `src/tui.jl`, change the signature and body of `start_live!`:

```julia
function start_live!(; host::AbstractString = "127.0.0.1",
                       port::Integer = 57120,
                       cps::Real = 0.5,
                       lookahead::Real = 0.05,
                       plugins::Bool = true)
    if _LIVE_SCHEDULER[] !== nothing
        @warn "A live session is already running — returning the existing scheduler."
        return _LIVE_SCHEDULER[]
    end
    client = OSCClient(host, port)
    sched  = Scheduler(client; cps, lookahead)
    _LIVE_SCHEDULER[] = sched
    start!(sched)
    plugins && _load_plugins()
    return sched
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src/plugins.jl src/tui.jl test/test_plugins.jl
git commit -m "plugins: default_plugin_path + _load_plugins, wired into start_live!"
```

---

## Task 8: `[julia]` handler

**Files:**
- Modify: `src/plugin_handlers.jl`
- Create: `test/test_plugin_handlers.jl`
- Modify: `test/runtests.jl`
- Create: `test/fixtures/plugins/jul/plugin.toml`
- Create: `test/fixtures/plugins/jul/hook.jl`

- [ ] **Step 1: Create fixture**

Create `test/fixtures/plugins/jul/plugin.toml`:

```toml
name        = "jul"
version     = "0.1.0"
description = "fixture testing the [julia] handler"

[julia]
files = ["./hook.jl"]
```

Create `test/fixtures/plugins/jul/hook.jl`:

```julia
# Marker that the test can observe to confirm the file was included.
Main._ressac_jul_hook_loaded = true
```

- [ ] **Step 2: Write the failing tests**

Create `test/test_plugin_handlers.jl`:

```julia
using Test
using Ressac

@testset "plugin_handlers" begin
    @testset "[julia] handler includes each file into Main" begin
        # Reset the marker if a previous run left it.
        Main.eval(:(_ressac_jul_hook_loaded = false))
        m = Ressac.parse_manifest(joinpath(@__DIR__, "fixtures", "plugins", "jul"))
        # Call the julia-section handler directly.
        h = Ressac.get_section_handler(:julia)
        @test h !== nothing
        h(m.dir, m.sections["julia"], m.name)
        @test Main._ressac_jul_hook_loaded === true
    end

    @testset "[julia] missing file logs error, does not throw" begin
        h = Ressac.get_section_handler(:julia)
        @test_logs (:error, r"no such file|missing") match_mode=:any begin
            h("/nonexistent", Dict("files" => ["./nope.jl"]), "nope")
        end
    end
end
```

Add to `test/runtests.jl`:

```julia
    include("test_plugin_handlers.jl")
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -8`
Expected: `h !== nothing` fails (handler not registered yet).

- [ ] **Step 4: Write the [julia] handler**

In `src/plugin_handlers.jl`:

```julia
"""
    _handle_julia(plugin_dir, section_data, plugin_name)

Process `[julia]`: `files = ["./hook.jl", ...]`. Each file is resolved
relative to `plugin_dir` and `Base.include`d into `Main`. Missing or
errored files are logged at `@error` level; the next file still runs.
"""
function _handle_julia(plugin_dir, data, plugin_name)
    files = get(data, "files", String[])
    files isa AbstractVector ||
        throw(ArgumentError("plugin '$plugin_name' [julia] files must be an array"))
    for f in files
        path = isabspath(f) ? f : joinpath(plugin_dir, f)
        if !isfile(path)
            @error "plugin '$plugin_name' [julia]: no such file '$path'"
            continue
        end
        try
            Base.include(Main, path)
        catch err
            @error "plugin '$plugin_name' [julia] include('$path') raised: $(sprint(showerror, err))"
        end
    end
    return nothing
end

# Register at module load time.
register_section_handler!(:julia, _handle_julia)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src/plugin_handlers.jl test/test_plugin_handlers.jl test/runtests.jl test/fixtures/
git commit -m "plugins: [julia] handler — Base.include each file into Main"
```

---

## Task 9: `[samples]` handler

**Files:**
- Modify: `src/plugin_handlers.jl`
- Modify: `test/test_plugin_handlers.jl`
- Create: `test/fixtures/plugins/withsamples/plugin.toml`
- Create: `test/fixtures/plugins/withsamples/samples/.gitkeep`

- [ ] **Step 1: Create fixture**

Create `test/fixtures/plugins/withsamples/plugin.toml`:

```toml
name        = "withsamples"
version     = "0.1.0"
description = "fixture testing the [samples] handler"

[samples]
roots = ["./samples"]
```

```bash
mkdir -p test/fixtures/plugins/withsamples/samples
touch test/fixtures/plugins/withsamples/samples/.gitkeep
```

- [ ] **Step 2: Write the failing tests**

Append to `test/test_plugin_handlers.jl`:

```julia
    @testset "[samples] handler sends /dirt/loadSampleFolder per root" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.parse_manifest(joinpath(@__DIR__, "fixtures", "plugins", "withsamples"))
            h = Ressac.get_section_handler(:samples)
            @test h !== nothing
            h(m.dir, m.sections["samples"], m.name)
            @test length(mock.sent) == 1
            msg = Ressac.decode_message(mock.sent[1])
            @test msg.address == "/dirt/loadSampleFolder"
            @test length(msg.args) == 1
            sent_path = msg.args[1]
            @test isabspath(sent_path)
            @test endswith(sent_path, "/withsamples/samples")
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "[samples] missing root logs error" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            h = Ressac.get_section_handler(:samples)
            @test_logs (:error, r"not found|no such") match_mode=:any begin
                h("/tmp", Dict("roots" => ["./does-not-exist"]), "ghost")
            end
            @test isempty(mock.sent)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "[samples] without active scheduler logs error" begin
        Ressac._LIVE_SCHEDULER[] = nothing
        h = Ressac.get_section_handler(:samples)
        @test_logs (:error, r"no active") match_mode=:any begin
            h("/tmp", Dict("roots" => ["./samples"]), "ghost")
        end
    end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -8`
Expected: handler not registered.

- [ ] **Step 4: Write the [samples] handler**

Append to `src/plugin_handlers.jl`:

```julia
"""
    _handle_samples(plugin_dir, section_data, plugin_name)

Process `[samples]`: `roots = ["./samples", ...]`. For each root,
resolve to absolute path, validate it exists, and send a
`/dirt/loadSampleFolder` OSC message with the absolute path as a
String argument. SuperDirt-side OSCdef (in
`scripts/superdirt-startup.scd`) calls `~dirt.loadSoundFiles("<path>/*")`.

Errors:
- No active scheduler → `[ERROR] cannot load samples: no active session`.
- Root path doesn't exist → logged at `@error`, next root still tries.
"""
function _handle_samples(plugin_dir, data, plugin_name)
    sched = _LIVE_SCHEDULER[]
    if sched === nothing
        @error "plugin '$plugin_name' [samples]: no active session — cannot load samples"
        return nothing
    end
    roots = get(data, "roots", String[])
    roots isa AbstractVector ||
        throw(ArgumentError("plugin '$plugin_name' [samples] roots must be an array"))
    for r in roots
        path = isabspath(r) ? r : joinpath(plugin_dir, r)
        path = abspath(path)
        if !isdir(path)
            @error "plugin '$plugin_name' [samples]: path '$path' not found"
            continue
        end
        msg = OSCMessage("/dirt/loadSampleFolder", Any[path])
        send_osc(sched.osc, encode(msg))
    end
    return nothing
end

register_section_handler!(:samples, _handle_samples)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src/plugin_handlers.jl test/test_plugin_handlers.jl test/fixtures/
git commit -m "plugins: [samples] handler — OSC /dirt/loadSampleFolder per root"
```

---

## Task 10: `[synthdefs]` handler

**Files:**
- Modify: `src/plugin_handlers.jl`
- Modify: `test/test_plugin_handlers.jl`
- Create: `test/fixtures/plugins/withsynth/plugin.toml`
- Create: `test/fixtures/plugins/withsynth/synth.scd`

- [ ] **Step 1: Create fixture**

Create `test/fixtures/plugins/withsynth/plugin.toml`:

```toml
name        = "withsynth"
version     = "0.1.0"
description = "fixture for [synthdefs]"

[synthdefs]
files = ["./synth.scd"]
```

Create `test/fixtures/plugins/withsynth/synth.scd`:

```supercollider
// Minimal SynthDef for testing.
SynthDef(\bassline, { |out=0, freq=110, amp=0.5|
    Out.ar(out, SinOsc.ar(freq) * amp);
}).add;
```

- [ ] **Step 2: Write the failing tests**

Append to `test/test_plugin_handlers.jl`:

```julia
    @testset "[synthdefs] handler sends /dirt/evalSC with file content" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.parse_manifest(joinpath(@__DIR__, "fixtures", "plugins", "withsynth"))
            h = Ressac.get_section_handler(:synthdefs)
            @test h !== nothing
            h(m.dir, m.sections["synthdefs"], m.name)
            @test length(mock.sent) == 1
            msg = Ressac.decode_message(mock.sent[1])
            @test msg.address == "/dirt/evalSC"
            @test length(msg.args) == 1
            @test occursin("SynthDef", msg.args[1])
            @test occursin("bassline", msg.args[1])
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end

    @testset "[synthdefs] missing file logs error" begin
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            h = Ressac.get_section_handler(:synthdefs)
            @test_logs (:error, r"not found|no such") match_mode=:any begin
                h("/tmp", Dict("files" => ["./nope.scd"]), "ghost")
            end
            @test isempty(mock.sent)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
        end
    end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -8`
Expected: handler not registered.

- [ ] **Step 4: Write the [synthdefs] handler**

Append to `src/plugin_handlers.jl`:

```julia
"""
    _handle_synthdefs(plugin_dir, section_data, plugin_name)

Process `[synthdefs]`: `files = ["./synth.scd", ...]`. For each file,
read its content and send via `/dirt/evalSC` OSC message with the SCD
source as a `String` arg. SuperDirt-side OSCdef calls
`interpret(source)`.

Errors: missing file → logged at `@error`; absent session → logged
and abort.
"""
function _handle_synthdefs(plugin_dir, data, plugin_name)
    sched = _LIVE_SCHEDULER[]
    if sched === nothing
        @error "plugin '$plugin_name' [synthdefs]: no active session"
        return nothing
    end
    files = get(data, "files", String[])
    files isa AbstractVector ||
        throw(ArgumentError("plugin '$plugin_name' [synthdefs] files must be an array"))
    for f in files
        path = isabspath(f) ? f : joinpath(plugin_dir, f)
        if !isfile(path)
            @error "plugin '$plugin_name' [synthdefs]: no such file '$path'"
            continue
        end
        src = read(path, String)
        msg = OSCMessage("/dirt/evalSC", Any[src])
        send_osc(sched.osc, encode(msg))
    end
    return nothing
end

register_section_handler!(:synthdefs, _handle_synthdefs)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src/plugin_handlers.jl test/test_plugin_handlers.jl test/fixtures/
git commit -m "plugins: [synthdefs] handler — OSC /dirt/evalSC with SCD source"
```

---

## Task 11: Extend SuperDirt startup with OSCdefs

**Files:**
- Modify: `scripts/superdirt-startup.scd`

- [ ] **Step 1: Baseline — run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass (no Julia-side changes; this task is SC-side only).

- [ ] **Step 2: Add the OSCdefs**

Replace the entire body of `scripts/superdirt-startup.scd` with:

```supercollider
// scripts/superdirt-startup.scd
//
// Loaded by `start-superdirt` (defined in flake.nix). Boots scsynth,
// instantiates SuperDirt with 12 orbits listening on UDP 57120, and
// loads the sample library from $DIRT_SAMPLES_PATH (set by the
// launcher). In addition, installs two OSC responders used by Ressac's
// plugin handlers:
//
//   /dirt/loadSampleFolder <abspath:String>
//     Calls ~dirt.loadSoundFiles("<abspath>/*"). Used by the
//     [samples] section handler.
//
//   /dirt/evalSC <source:String>
//     Calls interpret(source) so the plugin's SCD code is evaluated in
//     the running sclang. Used by [synthdefs].
//
// Stay attached: Ctrl+C in the parent shell stops everything.

s.options.memSize    = 2**18;
s.options.numBuffers = 1024 * 64;
s.options.maxNodes   = 1024 * 32;

s.waitForBoot({
    var samplesPath = "DIRT_SAMPLES_PATH".getenv;

    ~dirt = SuperDirt(2, s);

    if (samplesPath.notNil and: { samplesPath.size > 0 }) {
        ("Loading samples from " ++ samplesPath).postln;
        ~dirt.loadSoundFiles(samplesPath ++ "/*");
    } {
        "DIRT_SAMPLES_PATH not set — running without samples".warn;
    };

    s.sync;
    ~dirt.start(57120, 0 ! 12);

    // OSCdefs added for Ressac plugin handlers.
    OSCdef(\ressacLoadSampleFolder, { |msg|
        var path = msg[1].asString;
        ("[ressac] loadSampleFolder " ++ path).postln;
        ~dirt.loadSoundFiles(path ++ "/*");
    }, '/dirt/loadSampleFolder');

    OSCdef(\ressacEvalSC, { |msg|
        var src = msg[1].asString;
        ("[ressac] evalSC (" ++ src.size.asString ++ " chars)").postln;
        src.interpret;
    }, '/dirt/evalSC');

    "".postln;
    "================================================".postln;
    "SuperDirt listening on UDP 57120 (12 orbits).".postln;
    ("Sample sets: " ++ ~dirt.soundLibrary.buffers.size.asString).postln;
    "Ressac OSC responders installed: /dirt/loadSampleFolder, /dirt/evalSC".postln;
    "================================================".postln;
});
```

- [ ] **Step 3: Sanity-check via just (manual)**

Run: `just audio` in a separate terminal. Expect the final block of log lines to include `Ressac OSC responders installed: /dirt/loadSampleFolder, /dirt/evalSC`. Then Ctrl+C to stop SuperDirt.

(If you can't run `just audio` in your current environment, skip this manual check. The Julia-side tests cover the OSC payload format; this commit's only concern is the SC-side wiring.)

- [ ] **Step 4: Verify all tests still pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/superdirt-startup.scd
git commit -m "superdirt: OSCdefs for /dirt/loadSampleFolder + /dirt/evalSC"
```

---

## Task 12: Update cheatsheet with Plugins section

**Files:**
- Modify: `docs/cheatsheet.md`

- [ ] **Step 1: Read the current cheatsheet end**

Run: `tail -20 docs/cheatsheet.md` to find a good insertion point. The "Common gotchas" section is currently last; we'll insert "Plugins" before it.

- [ ] **Step 2: Insert the new section**

In `docs/cheatsheet.md`, find the `## Common gotchas` line and insert immediately above it:

````markdown
## Plugins

Ressac looks for plugins on this path at session start (first hit wins
per plugin name):

```
./plugins/<name>/                       # cwd, commit alongside your set
~/.config/ressac/plugins/<name>/        # personal global toolkit
$RESSAC_PLUGIN_PATH (colon-separated)   # escape hatch / Nix store
```

A plugin is a directory with a `plugin.toml`:

```toml
name        = "funkit"
version     = "0.1.0"
description = "personal kicks + snares + a bassline synth"

[samples]
roots = ["./samples"]

[synthdefs]
files = ["./synths/bassline.scd"]

# Optional Julia hook — included into Main BEFORE the plugin's other
# sections run. Can call `Ressac.register_section_handler!` to add
# entirely new sections that downstream plugins can use.
[julia]
files = ["./hook.jl"]

# Optional load-order hint.
depends_on = ["some-other-plugin"]
```

To skip plugin loading for a session:

```julia
julia> start_live!(plugins=false)
```

Extending Ressac with a new section type is one call:

```julia
# in your plugin's hook.jl
Ressac.register_section_handler!(:midi, function (plugin_dir, data, name)
    # data is the [midi] table from the manifest
    # do your thing — install OSCdefs, MIDI bridges, etc.
end)
```

Plugins later in the load order that have `[midi]` in their manifest
will now have it processed by your handler.

````

- [ ] **Step 3: Commit**

```bash
git add docs/cheatsheet.md
git commit -m "docs: cheatsheet — Plugins section (search path, manifest, extension API)"
```

---

## Task 13: Update Ressac.jl exports + precompile workload

**Files:**
- Modify: `src/Ressac.jl`

- [ ] **Step 1: Add exports**

In `src/Ressac.jl`, after the existing `export live, ...` line, add:

```julia
export register_section_handler!, unregister_section_handler!
export load_plugin, default_plugin_path
```

- [ ] **Step 2: Extend the precompile workload**

In the `@compile_workload begin ... end` block in `src/Ressac.jl`, just before the closing `end`, append:

```julia
    # Plugins: parse a fixture manifest and walk discover/topo_sort to
    # warm up TOML parsing + the loader paths.
    fixture = joinpath(@__DIR__, "..", "test", "fixtures", "plugins", "foo")
    if isfile(joinpath(fixture, "plugin.toml"))
        try
            m = parse_manifest(fixture)
            discover_plugins([dirname(fixture)])
            topo_sort([m])
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
git commit -m "plugins: export public API + extend precompile workload"
```

---

## Self-review summary

Mapping spec → tasks:

- §3 search path → Task 7 (`default_plugin_path`) + Task 4 (`discover_plugins`).
- §4 manifest format → Task 3 (`parse_manifest`).
- §5 section handler registry → Task 2 (`register_section_handler!` / `unregister` / `get`).
- §6 load flow → Task 6 (`load_plugin`) + Task 5 (`topo_sort`) + Task 7 (`_load_plugins` + `start_live!` wiring).
- §7 [samples] handler → Task 9 + Task 11 (SC-side OSCdef).
- §8 [synthdefs] handler → Task 10 + Task 11 (SC-side OSCdef).
- §9 [julia] handler → Task 8.
- §10 file layout → reflected in this plan's file list (top).
- §11 test strategy → distributed across Tasks 2-10. End-to-end coverage by mock-OSC injection in Tasks 9 & 10.
- §13 (organic / non-features) → mostly implicit: same public API for built-in + external (Tasks 8/9/10 register through Task 2's API), unknown sections warn (Task 6 test), no privileged paths.
