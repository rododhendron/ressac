# SC UGen Doc Autodiscover (Stage A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** At first boot of a live session, auto-populate `_DOCS` with ~500-600 SuperCollider UGen entries by shipping a discovery script to SC, parsing SCDoc HelpFiles into Markdown, and caching the result under `~/.cache/ressac/plugins/sc-autodiscover/docs/*.md` for fast warm boots.

**Architecture:** Two-plugin split — `plugins/sc-discoverer/` (in repo) is the runner that owns the SC script + Julia handler; `~/.cache/ressac/plugins/sc-autodiscover/` (in user cache) is the generated content, loaded as a regular plugin via the existing `[docs]` handler from sub-project 7. Cache invalidation is automatic via SHA-256 of `discover.scd` + SC's `Main.version` + `UGen.allSubclasses.size`.

**Tech Stack:** Julia 1.10+, existing `TOML` stdlib (for `cache_meta.toml`), `SHA` stdlib (auto-invalidation hash), `Dates` stdlib (ISO 8601 timestamps), existing OSC infrastructure (`/dirt/evalSC` for shipping SC code, `/ressac/*` for ack messages). SuperCollider 3.13+ (`UGen.allSubclasses`, `SCDoc.findHelpFile`).

---

## Spec deviation note

The design doc described `cache_meta.json`. The implementation uses
`cache_meta.toml` — TOML is already a project dep (used by every
plugin manifest), JSON is not. The cache_meta has a flat key-value
shape that TOML expresses without nesting. The MD frontmatter format
is unchanged (still TOML between `+++` fences, per sub-project 7).

---

## File structure

**New source files (in project repo):**
- `plugins/sc-discoverer/plugin.toml` — runner manifest (declares `[julia]` + custom `[sc_discover]` section)
- `plugins/sc-discoverer/bootstrap.jl` — registers `_handle_sc_discover` handler, OSC helpers, cache logic
- `plugins/sc-discoverer/discover.scd` — SC script (~250 lines)
- `test/test_sc_autodiscover.jl` — unit tests for the Julia helpers
- `test/fixtures/sc_autodiscover/` — fixture cache dir with 3 pre-written MD files for loader-integration tests

**Modified source files:**
- `src/plugin_registry.jl:230` — `default_plugin_path()` adds `~/.cache/ressac/plugins`
- `scripts/superdirt-startup.scd` — adds the `OSCdef(\ressacScMeta, …)` handler (5 lines)
- `src/tui_app.jl` — registers `:sc-rediscover` and `:sc-cache-info` commands
- `test/runtests.jl` — includes `test_sc_autodiscover.jl`

**Generated at runtime (not committed):**
- `~/.cache/ressac/plugins/sc-autodiscover/plugin.toml`
- `~/.cache/ressac/plugins/sc-autodiscover/cache_meta.toml`
- `~/.cache/ressac/plugins/sc-autodiscover/docs/*.md` (~500-600 files)

---

## Phase 1 — Julia cache helpers

### Task 1: `_sc_cache_dir` + `_sc_script_sha256` helpers

**Files:**
- Create: `plugins/sc-discoverer/bootstrap.jl`
- Create: `plugins/sc-discoverer/plugin.toml`
- Create: `test/test_sc_autodiscover.jl`
- Modify: `test/runtests.jl`

- [ ] **Step 1: Write the failing test**

Create `test/test_sc_autodiscover.jl`:
```julia
using Test
using Ressac

@testset "sc-autodiscover" begin
    @testset "_sc_cache_dir defaults to ~/.cache/ressac/plugins/sc-autodiscover" begin
        # No RESSAC_CACHE_DIR set
        delete!(ENV, "RESSAC_CACHE_DIR")
        @test Main._sc_cache_dir() ==
            joinpath(homedir(), ".cache", "ressac", "plugins", "sc-autodiscover")
    end

    @testset "_sc_cache_dir honours RESSAC_CACHE_DIR env var" begin
        ENV["RESSAC_CACHE_DIR"] = "/tmp/myressac"
        try
            @test Main._sc_cache_dir() ==
                joinpath("/tmp/myressac", "plugins", "sc-autodiscover")
        finally
            delete!(ENV, "RESSAC_CACHE_DIR")
        end
    end

    @testset "_sc_script_sha256 — same content, same hash" begin
        tmpdir = mktempdir()
        try
            p = joinpath(tmpdir, "discover.scd")
            write(p, "// hello\n")
            h1 = Main._sc_script_sha256(p)
            h2 = Main._sc_script_sha256(p)
            @test h1 == h2
            @test length(h1) == 64   # SHA-256 hex
        finally
            rm(tmpdir; recursive=true, force=true)
        end
    end

    @testset "_sc_script_sha256 — one-byte edit changes hash" begin
        tmpdir = mktempdir()
        try
            p = joinpath(tmpdir, "discover.scd")
            write(p, "// hello\n")
            h1 = Main._sc_script_sha256(p)
            write(p, "// hello!\n")
            h2 = Main._sc_script_sha256(p)
            @test h1 != h2
        finally
            rm(tmpdir; recursive=true, force=true)
        end
    end
end
```

- [ ] **Step 2: Create runner plugin manifest**

Write `plugins/sc-discoverer/plugin.toml`:
```toml
name        = "sc-discoverer"
version     = "0.1.0"
description = "Discovers SuperCollider UGens at first boot + caches their docs"

[julia]
files = ["./bootstrap.jl"]

[sc_discover]
# Handler defined in bootstrap.jl. Empty section — the [sc_discover]
# block exists purely as a marker so the loader invokes our handler.
```

- [ ] **Step 3: Create bootstrap.jl with the helpers**

Write `plugins/sc-discoverer/bootstrap.jl`:
```julia
# sc-discoverer runner — registers _handle_sc_discover so the
# plugin loader auto-runs SC UGen discovery at start_live!.
#
# Companion file: discover.scd (the SC introspection script).
# Generated content target: ~/.cache/ressac/plugins/sc-autodiscover/.

using SHA
using TOML
using Dates

"""
    _sc_cache_dir() -> String

Absolute path to the generated cache plugin directory. Override
via the `RESSAC_CACHE_DIR` env var (e.g. for Docker / read-only
Nix store scenarios). Defaults to `~/.cache/ressac`.
"""
_sc_cache_dir() = joinpath(
    get(ENV, "RESSAC_CACHE_DIR", joinpath(homedir(), ".cache", "ressac")),
    "plugins", "sc-autodiscover",
)

"""
    _sc_script_sha256(scd_path) -> String

SHA-256 hex digest of the SC script content at `scd_path`. Used by
`_sc_cache_valid` to detect any change to `discover.scd` and auto-
invalidate the cache — frees us from maintaining a manual version
constant. Cosmetic edits (whitespace, comments) DO trigger
re-discovery; acceptable since discovery is only at `start_live!`
and takes ~10s.
"""
_sc_script_sha256(scd_path::AbstractString) =
    bytes2hex(SHA.sha256(read(scd_path, String)))
```

- [ ] **Step 4: Wire test into runtests.jl**

In `test/runtests.jl`, add after `include("test_extension_registry_migration.jl")`:
```julia
    include("test_sc_autodiscover.jl")
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: `Test Summary: | Pass  Total   Time` with the 6 new assertions passing.

- [ ] **Step 6: Commit**

```bash
git add plugins/sc-discoverer/plugin.toml plugins/sc-discoverer/bootstrap.jl test/test_sc_autodiscover.jl test/runtests.jl
git commit -m "$(cat <<'EOF'
feat(sc-autodiscover): _sc_cache_dir + _sc_script_sha256 helpers

Scaffolds the sc-discoverer runner plugin. Two helpers in
bootstrap.jl: cache path resolution (honours RESSAC_CACHE_DIR env)
and SHA-256 of the SC script for auto cache invalidation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `_sc_cache_valid` — meta TOML parse + comparison

**Files:**
- Modify: `plugins/sc-discoverer/bootstrap.jl` (append helper)
- Modify: `test/test_sc_autodiscover.jl` (append testset)

- [ ] **Step 1: Add failing tests**

Append to `test/test_sc_autodiscover.jl` before the final `end`:
```julia
    @testset "_sc_cache_valid — missing meta → false" begin
        tmpdir = mktempdir()
        try
            scd = joinpath(tmpdir, "discover.scd")
            write(scd, "// noop")
            @test Main._sc_cache_valid(tmpdir, scd; sc_meta = ("3.13.0", 587)) == false
        finally
            rm(tmpdir; recursive=true, force=true)
        end
    end

    @testset "_sc_cache_valid — all match → true" begin
        tmpdir = mktempdir()
        try
            scd = joinpath(tmpdir, "discover.scd")
            write(scd, "// content\n")
            sha = Main._sc_script_sha256(scd)
            meta_path = joinpath(tmpdir, "cache_meta.toml")
            open(meta_path, "w") do io
                println(io, """
                sc_version             = "3.13.0"
                ugen_count             = 587
                generated_at           = "2026-05-29T14:23:11Z"
                discover_script_sha256 = "$sha"
                """)
            end
            @test Main._sc_cache_valid(tmpdir, scd; sc_meta = ("3.13.0", 587)) == true
        finally
            rm(tmpdir; recursive=true, force=true)
        end
    end

    @testset "_sc_cache_valid — sc_version mismatch → false" begin
        tmpdir = mktempdir()
        try
            scd = joinpath(tmpdir, "discover.scd")
            write(scd, "// content\n")
            sha = Main._sc_script_sha256(scd)
            meta_path = joinpath(tmpdir, "cache_meta.toml")
            open(meta_path, "w") do io
                println(io, """
                sc_version             = "3.13.0"
                ugen_count             = 587
                generated_at           = "2026-05-29T14:23:11Z"
                discover_script_sha256 = "$sha"
                """)
            end
            # Pretend SC is now 3.14.0
            @test Main._sc_cache_valid(tmpdir, scd; sc_meta = ("3.14.0", 587)) == false
        finally
            rm(tmpdir; recursive=true, force=true)
        end
    end

    @testset "_sc_cache_valid — ugen_count mismatch → false" begin
        tmpdir = mktempdir()
        try
            scd = joinpath(tmpdir, "discover.scd")
            write(scd, "// content\n")
            sha = Main._sc_script_sha256(scd)
            meta_path = joinpath(tmpdir, "cache_meta.toml")
            open(meta_path, "w") do io
                println(io, """
                sc_version             = "3.13.0"
                ugen_count             = 587
                generated_at           = "2026-05-29T14:23:11Z"
                discover_script_sha256 = "$sha"
                """)
            end
            @test Main._sc_cache_valid(tmpdir, scd; sc_meta = ("3.13.0", 600)) == false
        finally
            rm(tmpdir; recursive=true, force=true)
        end
    end

    @testset "_sc_cache_valid — script SHA mismatch → false" begin
        tmpdir = mktempdir()
        try
            scd = joinpath(tmpdir, "discover.scd")
            write(scd, "// content\n")
            meta_path = joinpath(tmpdir, "cache_meta.toml")
            open(meta_path, "w") do io
                println(io, """
                sc_version             = "3.13.0"
                ugen_count             = 587
                generated_at           = "2026-05-29T14:23:11Z"
                discover_script_sha256 = "wronghashvalue"
                """)
            end
            @test Main._sc_cache_valid(tmpdir, scd; sc_meta = ("3.13.0", 587)) == false
        finally
            rm(tmpdir; recursive=true, force=true)
        end
    end

    @testset "_sc_cache_valid — corrupted meta TOML → false + warning" begin
        tmpdir = mktempdir()
        try
            scd = joinpath(tmpdir, "discover.scd")
            write(scd, "// content\n")
            meta_path = joinpath(tmpdir, "cache_meta.toml")
            write(meta_path, "not = valid = toml = [[")
            @test_logs (:warn, r"corrupted") begin
                @test Main._sc_cache_valid(tmpdir, scd; sc_meta = ("3.13.0", 587)) == false
            end
        finally
            rm(tmpdir; recursive=true, force=true)
        end
    end

    @testset "_sc_cache_valid — sc_meta=nothing (SC unreachable) → false" begin
        tmpdir = mktempdir()
        try
            scd = joinpath(tmpdir, "discover.scd")
            write(scd, "// content\n")
            sha = Main._sc_script_sha256(scd)
            meta_path = joinpath(tmpdir, "cache_meta.toml")
            open(meta_path, "w") do io
                println(io, """
                sc_version             = "3.13.0"
                ugen_count             = 587
                generated_at           = "2026-05-29T14:23:11Z"
                discover_script_sha256 = "$sha"
                """)
            end
            # SC roundtrip failed
            @test Main._sc_cache_valid(tmpdir, scd; sc_meta = nothing) == false
        finally
            rm(tmpdir; recursive=true, force=true)
        end
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`

Expected: `UndefVarError: _sc_cache_valid not defined in Main`.

- [ ] **Step 3: Implement `_sc_cache_valid`**

Append to `plugins/sc-discoverer/bootstrap.jl`:
```julia
"""
    _sc_cache_valid(cache_dir, scd_path; sc_meta) -> Bool

Decide whether the cache at `cache_dir` is up to date.

`sc_meta` is a tuple `(sc_version::String, ugen_count::Int)` obtained
from an OSC roundtrip with SC, or `nothing` if the roundtrip failed.
A failed roundtrip is treated as "assume invalid" — we can't prove
freshness without SC, so re-discover.

Returns `false` (and triggers re-discovery) when ANY of:
  * the meta file is missing
  * the meta TOML is corrupted
  * `sc_meta === nothing` (SC unreachable)
  * `sc_version`, `ugen_count`, or `discover_script_sha256` mismatch
"""
function _sc_cache_valid(cache_dir::AbstractString, scd_path::AbstractString;
                        sc_meta::Union{Tuple{AbstractString,Integer}, Nothing})
    sc_meta === nothing && return false
    meta_path = joinpath(cache_dir, "cache_meta.toml")
    isfile(meta_path) || return false
    meta = try
        TOML.parsefile(meta_path)
    catch
        @warn "sc-autodiscover: cache_meta.toml corrupted, will rediscover"
        return false
    end
    sha_now = _sc_script_sha256(scd_path)
    get(meta, "discover_script_sha256", "") == sha_now || return false
    sc_version, sc_ugen_count = sc_meta
    get(meta, "sc_version", "")  == sc_version  &&
    get(meta, "ugen_count", -1)  == sc_ugen_count
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: all tests pass (~7 new assertions added).

- [ ] **Step 5: Commit**

```bash
git add plugins/sc-discoverer/bootstrap.jl test/test_sc_autodiscover.jl
git commit -m "$(cat <<'EOF'
feat(sc-autodiscover): _sc_cache_valid cache check

Validates the cache_meta.toml against (a) the live SC version,
(b) the current UGen count, and (c) the SHA of discover.scd.
Treats a failed SC roundtrip (sc_meta=nothing) as invalid so a
cold-SC boot just skips the cache without crashing.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Plugin loader extension — scan `~/.cache/ressac/plugins`

**Files:**
- Modify: `src/plugin_registry.jl` — `default_plugin_path()`
- Modify: `test/test_plugins.jl` (append testset)

- [ ] **Step 1: Add failing test**

Append to `test/test_plugins.jl` before the final `end`:
```julia
    @testset "default_plugin_path includes ~/.cache/ressac/plugins" begin
        # Clear env to test default behaviour
        prev = get(ENV, "RESSAC_PLUGIN_PATH", nothing)
        delete!(ENV, "RESSAC_PLUGIN_PATH")
        try
            path = Ressac.default_plugin_path()
            cache_entry = joinpath(homedir(), ".cache", "ressac", "plugins")
            @test cache_entry in path
            # Order: project > config > cache
            config_entry = joinpath(homedir(), ".config", "ressac", "plugins")
            config_idx = findfirst(==(config_entry), path)
            cache_idx = findfirst(==(cache_entry), path)
            @test config_idx < cache_idx
        finally
            prev !== nothing && (ENV["RESSAC_PLUGIN_PATH"] = prev)
        end
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`

Expected: assertion failure — cache entry not in path.

- [ ] **Step 3: Update `default_plugin_path`**

In `src/plugin_registry.jl`, find the `default_plugin_path` function (around line 230) and update:

Before:
```julia
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
```

After:
```julia
function default_plugin_path()
    path = String[joinpath(pwd(), "plugins")]
    push!(path, joinpath(homedir(), ".config", "ressac", "plugins"))
    push!(path, joinpath(homedir(), ".cache",  "ressac", "plugins"))
    extra = get(ENV, "RESSAC_PLUGIN_PATH", "")
    if !isempty(extra)
        for entry in split(extra, ':')
            isempty(entry) || push!(path, String(entry))
        end
    end
    return path
end
```

Also update the docstring just above (line 219-229):

Before:
```
Plugin search path used by default at session start. Order:
1. `\$PWD/plugins`
2. `~/.config/ressac/plugins`
3. Entries from `\$RESSAC_PLUGIN_PATH` (`:`-separated).
```

After:
```
Plugin search path used by default at session start. Order:
1. `\$PWD/plugins`                        — project tree
2. `~/.config/ressac/plugins`             — user overrides
3. `~/.cache/ressac/plugins`              — auto-generated (e.g. sc-autodiscover)
4. Entries from `\$RESSAC_PLUGIN_PATH` (`:`-separated).

The cache path is third so user overrides (config) win over the
auto-generated content via the registry's last-wins on conflict.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/plugin_registry.jl test/test_plugins.jl
git commit -m "$(cat <<'EOF'
feat(plugins): scan ~/.cache/ressac/plugins after user config

Lets auto-generated content plugins (like sc-autodiscover) load
through the same loader as everything else. Order: project >
config > cache so user overrides win on conflict via last-wins.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — OSC roundtrip + ack listener

### Task 4: SC-side `/ressac/sc-meta` handler

**Files:**
- Modify: `scripts/superdirt-startup.scd` (append OSCdef)

- [ ] **Step 1: Add the SC handler**

In `scripts/superdirt-startup.scd`, find the section where other OSCdefs live (around the `OSCdef(\ressacEvalSC, …)` block, ~line 146-150) and append after the last OSCdef inside that block:

```scd
    OSCdef(\ressacScMeta, { |msg, time, addr|
        ("[ressac] sc-meta requested").postln;
        addr.sendMsg("/ressac/sc-meta-reply",
                     Main.version.asString,
                     UGen.allSubclasses.size);
    }, '/ressac/sc-meta');
```

Find the final `.postln` log at the end of the responders block (around line 508 in the original file) and update it to mention the new handler:

Before:
```scd
"Ressac OSC responders installed: /dirt/loadSampleFolder, /dirt/evalSC, /dirt/registerSample".postln;
```

After:
```scd
"Ressac OSC responders installed: /dirt/loadSampleFolder, /dirt/evalSC, /dirt/registerSample, /ressac/sc-meta".postln;
```

- [ ] **Step 2: Lint the SC script with `sclang -h`**

This is a syntax check only, no execution.

Run: `sclang -h scripts/superdirt-startup.scd 2>&1 | tail -10`

Expected: no parse errors. If `sclang` is not on the dev's PATH, skip this step and note in the commit that lint is deferred to manual integration testing.

- [ ] **Step 3: Commit**

```bash
git add scripts/superdirt-startup.scd
git commit -m "$(cat <<'EOF'
feat(sc): /ressac/sc-meta — reply with SC version + UGen count

5-line OSCdef. Ressac uses this in a roundtrip to decide whether
the sc-autodiscover cache is still valid (vs the live SC's state).
Untested in CI — verified by manual integration test once Phase 5
lands.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Julia `_sc_meta_roundtrip` + temporary OSC listener

**Files:**
- Modify: `plugins/sc-discoverer/bootstrap.jl` (append helpers)
- Modify: `test/test_sc_autodiscover.jl` (append testset)

- [ ] **Step 1: Add failing test**

The roundtrip needs a real SC running to test E2E. We unit-test the
listener installation/uninstallation via a mock callback path and
test the timeout path with a never-firing channel.

Append to `test/test_sc_autodiscover.jl`:
```julia
    @testset "_take_with_timeout — fires when value arrives" begin
        ch = Channel{Int}(1)
        @async (sleep(0.05); put!(ch, 42))
        @test Main._take_with_timeout(ch, 1.0) == 42
    end

    @testset "_take_with_timeout — returns nothing on timeout" begin
        ch = Channel{Int}(1)
        @test Main._take_with_timeout(ch, 0.1) === nothing
    end

    @testset "_sc_meta_roundtrip returns nothing when no scheduler" begin
        # When _LIVE_SCHEDULER[] is nothing, the function must not throw —
        # it returns nothing so _sc_cache_valid treats it as "assume invalid".
        prev = Ressac._LIVE_SCHEDULER[]
        Ressac._LIVE_SCHEDULER[] = nothing
        try
            @test Main._sc_meta_roundtrip(timeout = 0.5) === nothing
        finally
            Ressac._LIVE_SCHEDULER[] = prev
        end
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`

Expected: `UndefVarError: _take_with_timeout not defined`.

- [ ] **Step 3: Implement the helpers**

Append to `plugins/sc-discoverer/bootstrap.jl`:
```julia
"""
    _take_with_timeout(ch::Channel, timeout::Real) -> Union{T, Nothing}

Try to take a value from `ch` within `timeout` seconds. Returns the
value, or `nothing` on timeout. Used to bound the wait time on OSC
acks from SC.
"""
function _take_with_timeout(ch::Channel{T}, timeout::Real) where T
    timer = Timer(timeout) do _
        close(ch)
    end
    try
        v = try
            take!(ch)
        catch
            return nothing   # channel closed by timeout
        end
        return v
    finally
        close(timer)
    end
end

"""
    _sc_meta_roundtrip(; timeout = 3.0) -> Union{Tuple{String,Int}, Nothing}

Ship `/ressac/sc-meta` to SC, listen for `/ressac/sc-meta-reply <version> <count>`
on the OSC dispatch loop. Returns `(version, ugen_count)` on success or
`nothing` if the live scheduler isn't running, or if SC doesn't reply
within `timeout` seconds.

The listener is installed into `Ressac._OSC_AD_HOC_HANDLERS` (a
process-wide table consumed by `tui_scope.jl:_handle_osc_packet`)
and removed in the `finally`.
"""
function _sc_meta_roundtrip(; timeout::Real = 3.0)
    sched = Ressac._LIVE_SCHEDULER[]
    sched === nothing && return nothing
    ch = Channel{Tuple{String,Int}}(1)
    handler = (args) -> begin
        # args = [version::String, count::Int32]
        length(args) >= 2 || return
        v = String(args[1])
        c = Int(args[2])
        try; put!(ch, (v, c)); catch; end
    end
    Ressac._OSC_AD_HOC_HANDLERS["/ressac/sc-meta-reply"] = handler
    try
        Ressac.send_osc(sched.osc,
            Ressac.encode(Ressac.OSCMessage("/ressac/sc-meta", Any[])))
        _take_with_timeout(ch, timeout)
    finally
        delete!(Ressac._OSC_AD_HOC_HANDLERS, "/ressac/sc-meta-reply")
    end
end
```

- [ ] **Step 4: Wire the `_OSC_AD_HOC_HANDLERS` dispatch into the scope's OSC loop**

Find `src/tui_scope.jl` and the function that processes incoming OSC packets (around line 190-210 where `addr == "/ressac/trigger"` etc.). Just below the existing `if/elseif` chain, add the ad-hoc dispatch:

Before the closing `end` of that function:
```julia
            # Ad-hoc handlers installed by ephemeral callers (e.g.
            # sc-discoverer waiting for /ressac/sc-meta-reply or
            # /ressac/sc-discovery-done). Last in the chain so it
            # never overrides a built-in handler.
            elseif haskey(_OSC_AD_HOC_HANDLERS, addr)
                _OSC_AD_HOC_HANDLERS[addr](args)
```

At the top of the file (near the other module-level consts), add:
```julia
"""
    _OSC_AD_HOC_HANDLERS

Ephemeral OSC address → callback table. Installed by callers who
need a one-off response (e.g. `_sc_meta_roundtrip`). The callback
receives the message args and is expected to put a value into a
caller-owned Channel. Caller is responsible for installing the
entry before sending and removing it after (use a `finally`).
"""
const _OSC_AD_HOC_HANDLERS = Dict{String,Function}()
```

- [ ] **Step 5: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: tests pass.

- [ ] **Step 6: Commit**

```bash
git add plugins/sc-discoverer/bootstrap.jl src/tui_scope.jl test/test_sc_autodiscover.jl
git commit -m "$(cat <<'EOF'
feat(sc-autodiscover): _sc_meta_roundtrip + ad-hoc OSC dispatch

Generic ephemeral OSC handler table in tui_scope.jl
(_OSC_AD_HOC_HANDLERS) lets short-lived callers (sc-discoverer here,
future SC interactions later) install a one-off response handler.
_sc_meta_roundtrip uses it to round-trip /ressac/sc-meta and parse
the reply within a configurable timeout.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3 — Discovery handler + cache_meta writer

### Task 6: `_handle_sc_discover` — cache check + dispatch + ack wait

**Files:**
- Modify: `plugins/sc-discoverer/bootstrap.jl` (append handler + registration)
- Modify: `test/test_sc_autodiscover.jl` (append testset)

- [ ] **Step 1: Add failing tests**

Append to `test/test_sc_autodiscover.jl`:
```julia
    @testset "_handle_sc_discover — no live session → warn + return" begin
        prev = Ressac._LIVE_SCHEDULER[]
        Ressac._LIVE_SCHEDULER[] = nothing
        try
            @test_logs (:warn, r"no live session") begin
                # plugin_dir doesn't need to exist for the no-session path
                @test Main._handle_sc_discover("/nonexistent", Dict{String,Any}(),
                                                "sc-discoverer") === nothing
            end
        finally
            Ressac._LIVE_SCHEDULER[] = prev
        end
    end

    @testset "_handle_sc_discover — cache valid → skip discovery" begin
        # Set RESSAC_CACHE_DIR to a tmp root; the handler will resolve
        # cache_dir = $TMP/plugins/sc-autodiscover/
        tmp_root = mktempdir()
        cache_dir = joinpath(tmp_root, "plugins", "sc-autodiscover")
        mkpath(cache_dir)
        ENV["RESSAC_CACHE_DIR"] = tmp_root

        # Plugin dir (where discover.scd lives) — separate from cache dir.
        plugin_dir = mktempdir()
        scd_path = joinpath(plugin_dir, "discover.scd")
        write(scd_path, "// fixture content\n")
        sha = Main._sc_script_sha256(scd_path)

        # Write a valid cache_meta that matches the (mocked) SC state.
        open(joinpath(cache_dir, "cache_meta.toml"), "w") do io
            println(io, """
            sc_version             = "3.13.0"
            ugen_count             = 587
            generated_at           = "2026-05-29T14:23:11Z"
            discover_script_sha256 = "$sha"
            """)
        end

        # Mock the SC roundtrip by injecting the result via a test hook.
        # Approach: have _handle_sc_discover read an optional kwarg
        # `sc_meta_override` for testability. In production it's nothing,
        # so the real _sc_meta_roundtrip runs.
        try
            @test_logs (:info, r"cache fresh") begin
                @test Main._handle_sc_discover(plugin_dir, Dict{String,Any}(),
                    "sc-discoverer";
                    sc_meta_override = ("3.13.0", 587)) === nothing
            end
        finally
            delete!(ENV, "RESSAC_CACHE_DIR")
            rm(tmp_root; recursive=true, force=true)
            rm(plugin_dir; recursive=true, force=true)
        end
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10`

Expected: `UndefVarError: _handle_sc_discover not defined`.

- [ ] **Step 3: Implement `_handle_sc_discover`**

Append to `plugins/sc-discoverer/bootstrap.jl`:
```julia
"""
    _handle_sc_discover(plugin_dir, data, plugin_name; sc_meta_override=nothing)

Section handler for the `[sc_discover]` block in `plugins/sc-discoverer/plugin.toml`.

Flow:
  1. If no live session is up, log a warning and return (deferred to next boot).
  2. Roundtrip `/ressac/sc-meta` to learn SC's current state. The
     `sc_meta_override` kwarg lets tests inject a mocked value.
  3. If `_sc_cache_valid` reports the cache as fresh, log + return.
  4. Otherwise ship `discover.scd` via `/dirt/evalSC`, install an ack
     listener on `/ressac/sc-discovery-done`, and block until the ack
     arrives or 30s elapses.
  5. After ack, write `cache_meta.toml` capturing the current SC version,
     UGen count, generation timestamp, and the SHA of discover.scd.
"""
function _handle_sc_discover(plugin_dir, data, plugin_name;
                             sc_meta_override::Union{Tuple{AbstractString,Integer},Nothing} = nothing,
                             discovery_timeout::Real = 30.0)
    sched = Ressac._LIVE_SCHEDULER[]
    if sched === nothing
        @warn "sc-autodiscover: no live session, discovery deferred"
        return nothing
    end
    cache_dir = _sc_cache_dir()
    scd_path = joinpath(plugin_dir, "discover.scd")
    sc_meta = sc_meta_override === nothing ?
              _sc_meta_roundtrip(timeout = 3.0) :
              sc_meta_override
    if _sc_cache_valid(cache_dir, scd_path; sc_meta = sc_meta)
        @info "sc-autodiscover: cache fresh, skipping discovery"
        return nothing
    end
    @info "sc-autodiscover: cache invalid, running discovery (may take ~10s)"
    mkpath(joinpath(cache_dir, "docs"))
    script = read(scd_path, String)
    # Install ack listener BEFORE sending eval, to avoid a race.
    ack_ch = Channel{Int}(1)
    Ressac._OSC_AD_HOC_HANDLERS["/ressac/sc-discovery-done"] = (args) -> begin
        count = isempty(args) ? -1 : Int(args[1])
        try; put!(ack_ch, count); catch; end
    end
    try
        Ressac.send_osc(sched.osc,
            Ressac.encode(Ressac.OSCMessage("/dirt/evalSC", Any[script])))
        result = _take_with_timeout(ack_ch, discovery_timeout)
        if result === nothing
            @error "sc-autodiscover: discovery timed out after $(discovery_timeout)s"
            return nothing
        end
        @info "sc-autodiscover: discovered $result UGens"
        # Now Julia writes cache_meta.toml (SC doesn't know the SHA).
        sc_meta_post = sc_meta_override === nothing ?
                       _sc_meta_roundtrip(timeout = 3.0) :
                       sc_meta_override
        if sc_meta_post !== nothing
            _write_cache_meta(cache_dir, scd_path, sc_meta_post)
        end
    finally
        delete!(Ressac._OSC_AD_HOC_HANDLERS, "/ressac/sc-discovery-done")
    end
    return nothing
end

"""
    _write_cache_meta(cache_dir, scd_path, sc_meta)

Write `cache_meta.toml` capturing the SHA of `scd_path` plus the
SC version + UGen count from `sc_meta`. Called after a successful
discovery so subsequent boots can short-circuit.
"""
function _write_cache_meta(cache_dir, scd_path, sc_meta)
    sc_version, sc_ugen_count = sc_meta
    sha = _sc_script_sha256(scd_path)
    ts = Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SSZ")
    open(joinpath(cache_dir, "cache_meta.toml"), "w") do io
        println(io, "sc_version             = \"$sc_version\"")
        println(io, "ugen_count             = $sc_ugen_count")
        println(io, "generated_at           = \"$ts\"")
        println(io, "discover_script_sha256 = \"$sha\"")
    end
end

Ressac.register_section_handler!(:sc_discover, _handle_sc_discover)
```

- [ ] **Step 4: Run tests**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: tests pass.

- [ ] **Step 5: Commit**

```bash
git add plugins/sc-discoverer/bootstrap.jl test/test_sc_autodiscover.jl
git commit -m "$(cat <<'EOF'
feat(sc-autodiscover): _handle_sc_discover — cache check + dispatch + meta write

The full discovery handler. Short-circuits when cache is fresh, ships
discover.scd via /dirt/evalSC on miss, waits up to 30s for the
/ressac/sc-discovery-done ack, then writes cache_meta.toml capturing
the SC version + UGen count + SHA-256 of discover.scd. The
sc_meta_override kwarg lets tests inject SC state without standing
up a live session.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4 — SC discovery script (manual verification, no TDD)

The SC side cannot be unit-tested in CI (no headless SC). We
write the script in one task per concern, lint with `sclang -h`
after each, and verify via the manual integration test list at the
end of this plan.

### Task 7: SC script — UGen enumeration + outer scaffolding

**Files:**
- Create: `plugins/sc-discoverer/discover.scd`

- [ ] **Step 1: Write the script skeleton**

Create `plugins/sc-discoverer/discover.scd`:
```scd
// sc-discoverer / discover.scd
//
// Discovery script shipped by plugins/sc-discoverer/bootstrap.jl
// via /dirt/evalSC. Iterates UGen.allSubclasses, captures each
// UGen's signature + SCDoc body, writes <ClassName>.md files
// under the cache dir, sends /ressac/sc-discovery-done on completion.
//
// Receivers of OSC ack:
//   /ressac/sc-discovery-done <count:int>

(
var cacheDir, docsDir, manifestPath, ugens, count;
var writeUgenMd, scDocToMd, signaturesFor, jsonEscape;

cacheDir     = (Platform.userHomeDir +/+ ".cache" +/+ "ressac"
                +/+ "plugins" +/+ "sc-autodiscover").asString;
docsDir      = cacheDir +/+ "docs";
manifestPath = cacheDir +/+ "plugin.toml";

// Ensure the cache layout exists.
File.mkdir(cacheDir);
File.mkdir(docsDir);

// Auto-generated plugin.toml so the loader treats the cache as a
// normal plugin and the [docs] handler from sub-project 7 scans
// docs/*.md without any custom handling.
File.use(manifestPath, "w", { |f|
    f.write("name        = \"sc-autodiscover\"\n");
    f.write("version     = \"0.1.0\"\n");
    f.write("description = \"Auto-generated SuperCollider UGen docs\"\n");
    f.write("\n[docs]\ndir = \"docs\"\n");
});

// Enumerate non-abstract UGen subclasses (must respond to .ar).
ugens = UGen.allSubclasses.select { |class|
    class.class.findRespondingMethodFor(\ar).notNil
};
("[sc-discover] " ++ ugens.size.asString ++ " UGen classes to process").postln;

// (placeholder for helper definitions + main loop — filled in by
//  Tasks 8-11; this task's commit ships the scaffolding only)

count = 0;
ugens.do { |class|
    // TODO Tasks 8-11
    count = count + 1;
};

NetAddr.localAddr.sendMsg("/ressac/sc-discovery-done", count);
"[sc-discover] done".postln;
)
```

- [ ] **Step 2: Lint with `sclang -h`**

Run: `sclang -h plugins/sc-discoverer/discover.scd 2>&1 | tail -5`

Expected: no syntax errors. (If `sclang` not on PATH, skip and rely on manual test in Phase 5.)

- [ ] **Step 3: Commit**

```bash
git add plugins/sc-discoverer/discover.scd
git commit -m "$(cat <<'EOF'
feat(sc-autodiscover): discover.scd scaffolding — cache dir + UGen enum

Sets up the cache dir, auto-writes plugin.toml so the loader treats
the cache as a normal plugin, enumerates UGen.allSubclasses filtered
for non-abstract classes. Main loop body is filled by Tasks 8-11.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: SC script — signature extraction

**Files:**
- Modify: `plugins/sc-discoverer/discover.scd`

- [ ] **Step 1: Add the signatures helper**

In `plugins/sc-discoverer/discover.scd`, replace the `// (placeholder for helper definitions …` block with the `signaturesFor` function. Find the line `// TODO Tasks 8-11` and replace with the call.

Inside the `(...)` scoped block, before the `count = 0;` line, add:

```scd
signaturesFor = { |class|
    var out = ();
    [\ar, \kr, \ir].do { |rate|
        var m = class.class.findRespondingMethodFor(rate);
        if (m.notNil) {
            var argNames = m.argNames;
            var defaults = m.prototypeFrame;
            // Drop the implicit `this` arg at index 0.
            var pairs = (1 .. (argNames.size - 1)).collect { |i|
                (name: argNames[i], default: defaults[i])
            };
            out[rate] = pairs;
        };
    };
    out
};
```

And replace the loop body `// TODO Tasks 8-11` with:

```scd
    var sigs = signaturesFor.value(class);
    // (Tasks 9-10 add: parse SCDoc, write MD)
    // For now we still increment count so the ack is emitted.
```

- [ ] **Step 2: Lint with `sclang -h`**

Run: `sclang -h plugins/sc-discoverer/discover.scd 2>&1 | tail -5`

Expected: no syntax errors.

- [ ] **Step 3: Commit**

```bash
git add plugins/sc-discoverer/discover.scd
git commit -m "$(cat <<'EOF'
feat(sc-autodiscover): discover.scd — signatures extraction

signaturesFor pulls (name, default) tuples for each rate
(.ar/.kr/.ir) a class responds to. Uses Method#argNames and
prototypeFrame, drops the implicit `this` at index 0.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: SC script — SCDoc parser + reformat to Markdown

**Files:**
- Modify: `plugins/sc-discoverer/discover.scd`

- [ ] **Step 1: Add the parser helper**

Before the `signaturesFor = ...` line, add:

```scd
// Parse a .schelp file's content into (short, body, category) where:
//   short    = first paragraph of the description:: block, max 200 chars
//   body     = SCDoc reformatted to Markdown (## Description, ### .ar,
//              - **arg** — …, ```sclang …``` examples)
//   category = first segment after `UGens>` in `categories::`
scDocToMd = { |helpPath|
    var src = "", short = "", body = "", category = "";
    var lines, currentBlock = "", currentArg = nil, mdParts, descPara = "";
    var hadDescription = false, hadExamples = false;

    if (File.exists(helpPath)) {
        src = File.readAllString(helpPath);
    } {
        // No help file — return empty fields, caller still ships
        // an entry with the signature-only frontmatter.
        ^(short: "", body: "", category: "")
    };

    lines = src.split($\n);
    mdParts = List.new;

    // First pass: extract `categories::` line if present.
    lines.do { |ln|
        if (ln.beginsWith("categories::")) {
            var cats = ln.drop(12).trim.split($\>);
            // e.g. "UGens>Generators>Deterministic" → "Generators" → lowercased
            if (cats.size >= 2) {
                category = cats[1].trim.toLower;
            };
        };
    };

    // Second pass: walk blocks. SCDoc blocks are introduced by
    // `keyword::[arg]` and terminated by a `::` on its own line OR
    // by the next top-level keyword. We track only the blocks we
    // care about (description, classmethods.method::ar/kr/ir,
    // argument::name, examples).
    lines.do { |ln|
        var stripped = ln.trim;
        // Block terminator
        if (stripped == "::") {
            currentBlock = "";
            currentArg = nil;
        } {
            // Block opener
            case
            { stripped.beginsWith("description::") } {
                currentBlock = "description";
                hadDescription = true;
                mdParts.add("## Description\n");
            }
            { stripped.beginsWith("argument::") } {
                currentArg = stripped.drop(10).trim;
                currentBlock = "argument";
                mdParts.add("- **" ++ currentArg ++ "** — ");
            }
            { stripped.beginsWith("method::") } {
                var name = stripped.drop(8).trim;
                if (#[\ar, \kr, \ir].includes(name.asSymbol)) {
                    currentBlock = "method";
                    mdParts.add("### ." ++ name ++ "\n");
                };
            }
            { stripped.beginsWith("examples::") } {
                hadExamples = true;
                currentBlock = "examples";
                mdParts.add("## Examples\n\n```sclang\n");
            }
            // Block body line (anything not a `::` keyword we've handled)
            { stripped.beginsWith("::").not and: { stripped.contains("::").not } } {
                if (currentBlock == "description") {
                    mdParts.add(ln ++ "\n");
                    // First non-blank line goes into descPara for `short`.
                    if (descPara.isEmpty and: { stripped.notEmpty }) {
                        descPara = stripped;
                    };
                };
                if (currentBlock == "argument") { mdParts.add(ln.trim ++ "\n") };
                if (currentBlock == "method")   { mdParts.add(ln ++ "\n") };
                if (currentBlock == "examples") { mdParts.add(ln ++ "\n") };
            };
        };
    };

    if (hadExamples) { mdParts.add("```\n") };

    body = mdParts.join("");
    short = descPara.copyRange(0, min(descPara.size - 1, 199));

    (short: short, body: body, category: category)
};
```

- [ ] **Step 2: Lint with `sclang -h`**

Run: `sclang -h plugins/sc-discoverer/discover.scd 2>&1 | tail -5`

Expected: no syntax errors.

- [ ] **Step 3: Commit**

```bash
git add plugins/sc-discoverer/discover.scd
git commit -m "$(cat <<'EOF'
feat(sc-autodiscover): discover.scd — scDocToMd parser

Walks SCDoc HelpFile content line-by-line, tracks the current block
(description, classmethods.method::ar/kr/ir, argument::name,
examples), emits Markdown: ## Description, ### .ar, - **arg** — text,
fenced ```sclang``` example blocks. Extracts the first non-blank
line of description:: for the tooltip `short` field. Missing
HelpFile → empty fields (signature-only entry).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: SC script — MD file writer

**Files:**
- Modify: `plugins/sc-discoverer/discover.scd`

- [ ] **Step 1: Add the writer helper**

Inside the `(...)` scope, after the `scDocToMd = …` definition, add:

```scd
// Build the TOML frontmatter string (between +++ fences) plus the body.
// Frontmatter fields match the design doc: name, short, tags, kwargs,
// aliases, examples.
writeUgenMd = { |class, sigs, parsed, outPath|
    var allKwargs = Set.new, fm = "", kwargsToml, tagsToml;

    // Collect all distinct kwarg names across rates.
    sigs.keysValuesDo { |rate, pairs|
        pairs.do { |p| allKwargs.add(p.name) };
    };

    kwargsToml = "[" ++ allKwargs.asArray.collect { |n| "\"" ++ n.asString ++ "\"" }.join(", ") ++ "]";
    tagsToml   = "[\"sc-ugen\"";
    if (parsed.category.notNil and: { parsed.category.notEmpty }) {
        tagsToml = tagsToml ++ ", \"" ++ parsed.category ++ "\"";
    };
    tagsToml = tagsToml ++ "]";

    fm = fm ++ "+++\n";
    fm = fm ++ "name = \"" ++ class.name.asString ++ "\"\n";
    fm = fm ++ "short = \"" ++ parsed.short.replace("\"", "'") ++ "\"\n";
    fm = fm ++ "tags = " ++ tagsToml ++ "\n";
    fm = fm ++ "kwargs = " ++ kwargsToml ++ "\n";
    fm = fm ++ "aliases = []\n";
    fm = fm ++ "examples = []\n";
    fm = fm ++ "+++\n\n";
    fm = fm ++ "# " ++ class.name.asString ++ "\n\n";

    // Signature section
    fm = fm ++ "## Signatures\n\n";
    sigs.keysValuesDo { |rate, pairs|
        var pieces = pairs.collect { |p|
            p.name.asString ++ "=" ++ p.default.asString
        };
        fm = fm ++ "- `" ++ class.name.asString ++ "." ++ rate.asString ++ "(" ++ pieces.join(", ") ++ ")`\n";
    };
    fm = fm ++ "\n";

    // Body from SCDoc
    fm = fm ++ parsed.body;

    File.use(outPath, "w", { |f| f.write(fm) });
};
```

- [ ] **Step 2: Lint with `sclang -h`**

Run: `sclang -h plugins/sc-discoverer/discover.scd 2>&1 | tail -5`

Expected: no syntax errors.

- [ ] **Step 3: Commit**

```bash
git add plugins/sc-discoverer/discover.scd
git commit -m "$(cat <<'EOF'
feat(sc-autodiscover): discover.scd — writeUgenMd

Composes the TOML frontmatter (name, short, tags, kwargs, aliases,
examples) + Signatures section + parsed body, writes to
<docsDir>/<ClassName>.md. Quotes in short are converted to single
quotes to keep the TOML valid (we don't escape — simpler than
adding a full TOML escaper in SC).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: SC script — main orchestrator + cleanup

**Files:**
- Modify: `plugins/sc-discoverer/discover.scd`

- [ ] **Step 1: Wire the main loop**

Replace the loop body that was:

```scd
ugens.do { |class|
    var sigs = signaturesFor.value(class);
    // (Tasks 9-10 add: parse SCDoc, write MD)
    // For now we still increment count so the ack is emitted.
    count = count + 1;
};
```

With:

```scd
// Clean stale MD files before regenerating. Keeps the docs dir
// in sync with the current UGen list (drops files for UGens that
// vanished after a sc3-plugins uninstall, etc.).
File.deleteAll(docsDir);
File.mkdir(docsDir);

ugens.do { |class|
    var sigs, helpPath, parsed, outPath;
    sigs     = signaturesFor.value(class);
    helpPath = SCDoc.helpTargetDir +/+ "Classes" +/+ class.name.asString ++ ".schelp";
    parsed   = scDocToMd.value(helpPath);
    outPath  = docsDir +/+ class.name.asString ++ ".md";
    writeUgenMd.value(class, sigs, parsed, outPath);
    count = count + 1;
};
```

- [ ] **Step 2: Lint with `sclang -h`**

Run: `sclang -h plugins/sc-discoverer/discover.scd 2>&1 | tail -5`

Expected: no syntax errors.

- [ ] **Step 3: Commit**

```bash
git add plugins/sc-discoverer/discover.scd
git commit -m "$(cat <<'EOF'
feat(sc-autodiscover): discover.scd — main orchestrator

Wipes the docs dir, iterates UGens, locates each HelpFile via
SCDoc.helpTargetDir (typically the SC IDE help install path),
parses + writes <ClassName>.md, increments count, ships the
/ressac/sc-discovery-done ack at the end with the final count.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 5 — User-facing commands + acceptance verification

### Task 12: `:sc-rediscover` and `:sc-cache-info` commands

**Files:**
- Modify: `src/tui_app.jl` (register two ex-commands)

- [ ] **Step 1: Locate the command registration section**

In `src/tui_app.jl`, find a region near other `_register_literal!` calls (e.g. around the `:starter` registration at line ~1986). Add the two new commands.

- [ ] **Step 2: Add the command implementations**

Append after the `:starter` registration block:

```julia
# ── SC autodiscover commands ─────────────────────────────────────────
_register_literal!(m -> _sc_rediscover_command!(m), "sc-rediscover")
_register_literal!(m -> _sc_cache_info_command!(m), "sc-cache-info")

"""
    _sc_rediscover_command!(m)

Force re-discovery of SC UGen docs. Deletes `cache_meta.toml` so the
next `_handle_sc_discover` invocation treats the cache as invalid,
then calls the handler synchronously. The docs/*.md files stay in
place during the delete — if discovery fails halfway, the user
still has the old docs to fall back on.
"""
function _sc_rediscover_command!(m::RessacApp)
    sched = _LIVE_SCHEDULER[]
    if sched === nothing
        _push_app_log!(m,
            "[ERROR] :sc-rediscover requires an active SC session — start the live first")
        return
    end
    cache_dir = Main._sc_cache_dir()
    meta_path = joinpath(cache_dir, "cache_meta.toml")
    if isfile(meta_path)
        rm(meta_path)
        _push_app_log!(m, "[INFO] :sc-rediscover — cleared cache meta, re-running discovery")
    end
    plugin_dir = joinpath(pwd(), "plugins", "sc-discoverer")
    try
        Main._handle_sc_discover(plugin_dir, Dict{String,Any}(), "sc-discoverer")
        _push_app_log!(m, "[INFO] :sc-rediscover — done. Restart the live to reload _DOCS.")
    catch err
        _push_app_log!(m, "[ERROR] :sc-rediscover failed: $(sprint(showerror, err))")
    end
end

"""
    _sc_cache_info_command!(m)

Print the contents of `cache_meta.toml` + cache dir path to the log.
Useful for debugging stale caches or verifying SC version matches.
"""
function _sc_cache_info_command!(m::RessacApp)
    cache_dir = Main._sc_cache_dir()
    _push_app_log!(m, "[INFO] :sc-cache-info — cache dir: $cache_dir")
    meta_path = joinpath(cache_dir, "cache_meta.toml")
    if !isfile(meta_path)
        _push_app_log!(m, "[INFO] :sc-cache-info — no cache_meta.toml yet (never discovered)")
        return
    end
    for line in eachline(meta_path)
        _push_app_log!(m, "[INFO]   $line")
    end
    docs_dir = joinpath(cache_dir, "docs")
    if isdir(docs_dir)
        n = count(f -> endswith(f, ".md"), readdir(docs_dir))
        _push_app_log!(m, "[INFO] :sc-cache-info — $n MD files in cache")
    end
end
```

- [ ] **Step 3: Run the full test suite**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`

Expected: all tests pass (no new tests for these commands — they're trivial wrappers, manually verified in the integration tests below).

- [ ] **Step 4: Commit**

```bash
git add src/tui_app.jl
git commit -m "$(cat <<'EOF'
feat(tui): :sc-rediscover and :sc-cache-info commands

:sc-rediscover clears cache_meta.toml and re-runs the handler.
:sc-cache-info logs the cache path + meta contents + MD file count.
Both require an active SC session; no-session yields a clear error.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: Manual integration test pass

**Files:** (none — verification only)

This task is human-driven verification against a live SuperCollider
session. The implementer follows each step and records the outcome
in the commit message.

- [ ] **Step 1: Clean slate**

```bash
rm -rf ~/.cache/ressac/plugins/sc-autodiscover/
```

- [ ] **Step 2: Start the live session**

Launch Ressac with SC running. Watch the boot log for:

```
[INFO] sc-autodiscover: cache invalid, running discovery (may take ~10s)
[INFO] sc-autodiscover: discovered <N> UGens
```

Where `<N>` ≥ 300. Time elapsed ≤ 30s.

- [ ] **Step 3: Verify file generation**

```bash
ls ~/.cache/ressac/plugins/sc-autodiscover/docs/ | wc -l
```

Expected: ≥ 300 `.md` files.

```bash
cat ~/.cache/ressac/plugins/sc-autodiscover/cache_meta.toml
```

Expected: 4 lines (sc_version, ugen_count, generated_at, discover_script_sha256).

- [ ] **Step 4: Verify registry lookup**

In the Ressac TUI, run:

```
:doc SinOsc
:doc EnvGen
:doc LFNoise0
```

Each should produce a tooltip with non-empty `short`. Hovering over
`SinOsc` in an editor pane should also show the live doc bar.

- [ ] **Step 5: Verify warm boot**

Quit Ressac, restart. Watch the boot log for:

```
[INFO] sc-autodiscover: cache fresh, skipping discovery
```

Time from boot to TUI ready should be no more than ~150 ms over the
sub-project 7 baseline (so ≤ 350 ms total).

- [ ] **Step 6: Verify `:sc-rediscover`**

In the live TUI:

```
:sc-rediscover
```

Watch for re-discovery log. Cache regenerates.

- [ ] **Step 7: Verify `:sc-cache-info`**

```
:sc-cache-info
```

Should print 4 meta lines + file count.

- [ ] **Step 8: Verify forced invalidation**

Manually edit `~/.cache/ressac/plugins/sc-autodiscover/cache_meta.toml` —
change `sc_version` to `"0.0.0"`. Restart Ressac. Watch for re-discovery
trigger.

- [ ] **Step 9: Record results in a verification commit**

```bash
git commit --allow-empty -m "$(cat <<'EOF'
test(sc-autodiscover): manual integration pass on 2026-XX-XX

Cold cache: <N> UGens discovered in <T>s.
Warm cache: boot time +<delta>ms over baseline.
:sc-rediscover, :sc-cache-info, forced invalidation all behaved
as specified.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Fill in `<N>`, `<T>`, `<delta>` with the actual measurements.

---

## Acceptance verification

After all 13 tasks complete, verify against the design's acceptance criteria:

- [ ] `plugins/sc-discoverer/` exists with `plugin.toml`, `bootstrap.jl`, `discover.scd`
- [ ] `default_plugin_path()` includes `~/.cache/ressac/plugins` (test passes)
- [ ] Cold-cache `start_live!` populates ≥ 300 MD files under `~/.cache/ressac/plugins/sc-autodiscover/docs/` (manual)
- [ ] Each MD has valid TOML frontmatter with `name`, `short`, `tags = ["sc-ugen", ...]`, `kwargs`
- [ ] `Ressac.lookup_doc("SinOsc")`, `lookup_doc("EnvGen")`, `lookup_doc("LFNoise0")` return entries with `body != ""`
- [ ] Warm-boot does not trigger discovery (`[INFO] cache fresh` in log)
- [ ] Boot time ≤ 350 ms warm (manual)
- [ ] `:sc-rediscover` works without manual cache cleanup
- [ ] `:sc-cache-info` logs cache meta + file count
- [ ] Test suite stays green (1509 baseline + new tests)
- [ ] Manual cold-cache discovery completes in ≤ 30s
