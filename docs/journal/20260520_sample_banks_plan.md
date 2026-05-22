# Sample Bank Plugins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement sub-project 2 (sample bank plugins) per spec `docs/journal/20260520_sample_banks_design.md` — `[samples.bank]` for aliasing + multi-bank, `[samples.metadata.*]` for per-bank metadata, a Julia-side registry, the `K` preview-under-cursor TUI binding, the `:samples` ex-command, and a new SuperDirt `/dirt/registerSample` OSCdef.

**Architecture:** Extend the existing `_handle_samples` in `plugin_handlers.jl` to populate a new `_SAMPLE_REGISTRY` (in `plugins.jl`) from both `[samples].roots` (filesystem scan) and `[samples.bank]` entries (explicit). Metadata is attached at registration. TUI dispatcher gains one keystroke (`K`) and one ex-command (`:samples`). One new SuperDirt OSCdef wires the alias-by-name registration server-side.

**Tech Stack:** Julia 1.10+, TOML stdlib, Test stdlib, existing `OSCClient`, `MockOSCClient` for handler tests.

---

## File structure

| File | Status | Responsibility |
|---|---|---|
| `src/plugins.jl` | extend | Add `SampleEntry` struct, `_SAMPLE_REGISTRY` Dict, `register_sample!`, `sample_info`, `list_samples`. |
| `src/plugin_handlers.jl` | extend | Rewrite `_handle_samples`: scan `roots`, read `[samples.bank]`, register entries, attach metadata, send OSC. |
| `src/tui_bindings.jl` | extend | `K` keystroke (normal mode) → preview helper. `:samples …` in `_execute_ex_command!`. |
| `scripts/superdirt-startup.scd` | extend | New `OSCdef(\ressacRegisterSample)`. |
| `src/Ressac.jl` | extend | Export `SampleEntry`, `sample_info`, `list_samples`. |
| `test/test_plugins.jl` | extend | Registry round-trip tests (independent of handlers). |
| `test/test_plugin_handlers.jl` | extend | Bank/metadata loading + OSC packet shipped + registry populated. |
| `test/test_tui_bindings.jl` | extend | `K` preview path with MockOSCClient + `:samples` ex-command. |
| `test/fixtures/plugins/withbanks/` | **new** | Fixture plugin: `[samples.bank]` (one file + one dir) + metadata. |
| `docs/cheatsheet.md` | extend | `[samples.bank]` syntax + `:samples` + `K` workflow. |

---

## Task 1: Add SampleEntry struct + registry

**Files:**
- Modify: `src/plugins.jl`
- Modify: `test/test_plugins.jl`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_plugins.jl` inside the outer `@testset "plugins"`:

```julia
    @testset "sample registry" begin
        # Always start clean to keep tests independent.
        empty!(Ressac._SAMPLE_REGISTRY)

        @testset "register_sample! stores by name and looks up by sample_info" begin
            ent = Ressac.SampleEntry(:kicky, "funkit", "/tmp/k.wav",
                                     ["/tmp/k.wav"], Dict("bpm" => 120))
            Ressac.register_sample!(ent)
            got = Ressac.sample_info(:kicky)
            @test got !== nothing
            @test got.name == :kicky
            @test got.plugin == "funkit"
            @test got.variants == ["/tmp/k.wav"]
            @test got.metadata["bpm"] == 120
            empty!(Ressac._SAMPLE_REGISTRY)
        end

        @testset "sample_info returns nothing for unknown names" begin
            @test Ressac.sample_info(:does_not_exist) === nothing
        end

        @testset "shadow: second registration with same name warns and is skipped" begin
            a = Ressac.SampleEntry(:dup, "p1", "/a", ["/a"], Dict{String,Any}())
            b = Ressac.SampleEntry(:dup, "p2", "/b", ["/b"], Dict{String,Any}())
            Ressac.register_sample!(a)
            @test_logs (:warn, r"dup.*shadow") match_mode=:any begin
                Ressac.register_sample!(b)
            end
            # First registration wins.
            @test Ressac.sample_info(:dup).plugin == "p1"
            empty!(Ressac._SAMPLE_REGISTRY)
        end

        @testset "list_samples returns entries sorted by plugin then name" begin
            for ent in [
                Ressac.SampleEntry(:b, "z", "/x", ["/x"], Dict{String,Any}()),
                Ressac.SampleEntry(:a, "z", "/y", ["/y"], Dict{String,Any}()),
                Ressac.SampleEntry(:c, "a", "/z", ["/z"], Dict{String,Any}()),
            ]
                Ressac.register_sample!(ent)
            end
            ordered = Ressac.list_samples()
            @test [(e.plugin, e.name) for e in ordered] ==
                  [("a", :c), ("z", :a), ("z", :b)]
            empty!(Ressac._SAMPLE_REGISTRY)
        end

        @testset "list_samples filters by regex" begin
            for ent in [
                Ressac.SampleEntry(:bd, "p", "/1", ["/1"], Dict{String,Any}()),
                Ressac.SampleEntry(:sn, "p", "/2", ["/2"], Dict{String,Any}()),
                Ressac.SampleEntry(:bd2, "p", "/3", ["/3"], Dict{String,Any}()),
            ]
                Ressac.register_sample!(ent)
            end
            kicks = Ressac.list_samples(r"^bd")
            @test sort([e.name for e in kicks]) == [:bd, :bd2]
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`
Expected: `UndefVarError: SampleEntry` and `register_sample!`.

- [ ] **Step 3: Write the registry**

Append to `src/plugins.jl`:

```julia
"""
    SampleEntry(name, plugin, bank_path, variants, metadata)

Identity of a single sample bank that's been loaded into Ressac.
Returned by [`sample_info`](@ref) and [`list_samples`](@ref).

- `name`        — Symbol used in patterns (`:kicky` → `s "kicky"`)
- `plugin`      — name of the plugin that contributed this bank
- `bank_path`   — absolute path to the file or directory backing the bank
- `variants`    — sorted absolute paths of the underlying audio files
                  (1 element for file-banks, ≥1 for directory-banks)
- `metadata`    — verbatim contents of `[samples.metadata.<name>]`,
                  empty Dict if none was provided
"""
struct SampleEntry
    name::Symbol
    plugin::String
    bank_path::String
    variants::Vector{String}
    metadata::Dict{String,Any}
end

"""
    _SAMPLE_REGISTRY

Module-level registry of every sample bank that's currently loaded,
keyed by short name. Populated by the `[samples]` handler at plugin load.
"""
const _SAMPLE_REGISTRY = Dict{Symbol,SampleEntry}()

"""
    register_sample!(entry::SampleEntry)

Register a sample bank. If `entry.name` is already registered, the new
entry is skipped and a `[WARN]` is logged (first-wins, same convention
as plugin shadowing).
"""
function register_sample!(entry::SampleEntry)
    if haskey(_SAMPLE_REGISTRY, entry.name)
        existing = _SAMPLE_REGISTRY[entry.name]
        @warn "sample bank '$(entry.name)' shadowed by plugin '$(entry.plugin)' (already loaded from '$(existing.plugin)')"
        return entry
    end
    _SAMPLE_REGISTRY[entry.name] = entry
    return entry
end

"""
    sample_info(name::Symbol) -> Union{SampleEntry, Nothing}
"""
sample_info(name::Symbol) = get(_SAMPLE_REGISTRY, name, nothing)

"""
    list_samples(pattern::Regex = r"") -> Vector{SampleEntry}

All registered sample banks whose `name` matches `pattern`, sorted by
`(plugin, name)`. Default pattern matches everything.
"""
function list_samples(pattern::Regex = r"")
    matches = SampleEntry[]
    for (name, entry) in _SAMPLE_REGISTRY
        occursin(pattern, String(name)) && push!(matches, entry)
    end
    sort!(matches, by = e -> (e.plugin, String(e.name)))
    return matches
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass; count goes 324 → ~334.

- [ ] **Step 5: Commit**

```bash
git add src/plugins.jl test/test_plugins.jl
git commit -m "plugins: SampleEntry struct + sample registry (register/info/list)"
```

---

## Task 2: Filesystem helpers for bank discovery

**Files:**
- Modify: `src/plugin_handlers.jl`
- Modify: `test/test_plugin_handlers.jl`

The handler needs two helpers shared between the `roots` scan and the
`[samples.bank]` path: list audio files in a directory (sorted) and
identify the bank path type (file / dir / missing).

- [ ] **Step 1: Write the failing tests**

Append to `test/test_plugin_handlers.jl` at the very end, just before the closing `end` of `@testset "plugin_handlers"`:

```julia
    @testset "_audio_files_in returns sorted wav/aiff/flac, skips others" begin
        mktempdir() do d
            for f in ["b.wav", "a.wav", "x.txt", "c.aiff", "d.flac", "skip.ds_store"]
                touch(joinpath(d, f))
            end
            files = Ressac._audio_files_in(d)
            @test basename.(files) == ["a.wav", "b.wav", "c.aiff", "d.flac"]
            # Absolute paths everywhere.
            @test all(isabspath, files)
        end
    end

    @testset "_audio_files_in missing dir returns empty" begin
        @test isempty(Ressac._audio_files_in("/no/such/path"))
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`
Expected: `UndefVarError: _audio_files_in`.

- [ ] **Step 3: Add the helpers**

Insert at the top of `src/plugin_handlers.jl`, just under the file-level comment:

```julia
const _AUDIO_EXTS = (".wav", ".aiff", ".aif", ".flac", ".ogg")

"""
    _audio_files_in(dir) -> Vector{String}

Sorted absolute paths to audio files inside `dir`. Recognises common
audio extensions (case-insensitive). Non-existent dir → empty vector.
"""
function _audio_files_in(dir::AbstractString)
    isdir(dir) || return String[]
    files = String[]
    for f in readdir(dir; join=false)
        ext = lowercase(splitext(f)[2])
        ext in _AUDIO_EXTS || continue
        push!(files, abspath(joinpath(dir, f)))
    end
    sort!(files)
    return files
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/plugin_handlers.jl test/test_plugin_handlers.jl
git commit -m "plugin_handlers: _audio_files_in helper (sorted, multi-extension)"
```

---

## Task 3: Withbanks fixture

**Files:**
- Create: `test/fixtures/plugins/withbanks/plugin.toml`
- Create: `test/fixtures/plugins/withbanks/curated/kicks/heavy_v3.wav`
- Create: `test/fixtures/plugins/withbanks/curated/snares/s1.wav`
- Create: `test/fixtures/plugins/withbanks/curated/snares/s2.wav`

- [ ] **Step 1: Create the empty WAV-named files**

```bash
mkdir -p test/fixtures/plugins/withbanks/curated/kicks
mkdir -p test/fixtures/plugins/withbanks/curated/snares
touch test/fixtures/plugins/withbanks/curated/kicks/heavy_v3.wav
touch test/fixtures/plugins/withbanks/curated/snares/s1.wav
touch test/fixtures/plugins/withbanks/curated/snares/s2.wav
```

(Empty files are fine — the handler only checks file existence and
listing, not audio validity.)

- [ ] **Step 2: Create the manifest**

`test/fixtures/plugins/withbanks/plugin.toml`:

```toml
name        = "withbanks"
version     = "0.1.0"
description = "fixture exercising [samples.bank] and [samples.metadata]"

[samples.bank]
kicky  = "./curated/kicks/heavy_v3.wav"
snares = "./curated/snares"

[samples.metadata.kicky]
bpm  = 120
key  = "C"
tags = ["heavy", "subby"]

[samples.metadata.snares]
tags = ["acoustic"]
```

- [ ] **Step 3: Verify the fixture parses with the existing manifest parser**

Run:
```bash
julia --project=. -e 'using Ressac; m = Ressac.parse_manifest("test/fixtures/plugins/withbanks"); println(m.name); println(keys(m.sections))'
```
Expected: prints `withbanks` and `Set("samples")` (or whatever container `keys` shows — the point is `samples` is in there).

- [ ] **Step 4: Run all tests, nothing should regress**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: still passing.

- [ ] **Step 5: Commit**

```bash
git add test/fixtures/plugins/withbanks/
git commit -m "plugins: fixture withbanks with [samples.bank] + metadata"
```

---

## Task 4: Extend _handle_samples for [samples.bank]

**Files:**
- Modify: `src/plugin_handlers.jl`
- Modify: `test/test_plugin_handlers.jl`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_plugin_handlers.jl`:

```julia
    @testset "[samples.bank] populates registry — file entry" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.parse_manifest(joinpath(@__DIR__, "fixtures", "plugins", "withbanks"))
            h = Ressac.get_section_handler(:samples)
            h(m.dir, m.sections["samples"], m.name)

            ent = Ressac.sample_info(:kicky)
            @test ent !== nothing
            @test ent.plugin == "withbanks"
            @test length(ent.variants) == 1
            @test endswith(ent.variants[1], "/curated/kicks/heavy_v3.wav")
            @test ent.metadata["bpm"] == 120
            @test ent.metadata["tags"] == ["heavy", "subby"]
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset "[samples.bank] populates registry — directory entry, sorted variants" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.parse_manifest(joinpath(@__DIR__, "fixtures", "plugins", "withbanks"))
            h = Ressac.get_section_handler(:samples)
            h(m.dir, m.sections["samples"], m.name)

            ent = Ressac.sample_info(:snares)
            @test ent !== nothing
            @test length(ent.variants) == 2
            @test basename.(ent.variants) == ["s1.wav", "s2.wav"]
            @test ent.metadata["tags"] == ["acoustic"]
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset "[samples.bank] sends /dirt/registerSample per bank entry" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.parse_manifest(joinpath(@__DIR__, "fixtures", "plugins", "withbanks"))
            h = Ressac.get_section_handler(:samples)
            h(m.dir, m.sections["samples"], m.name)

            register_msgs = [Ressac.decode_message(b) for b in mock.sent
                             if Ressac.decode_message(b).address == "/dirt/registerSample"]
            names_sent = sort([msg.args[1] for msg in register_msgs])
            @test names_sent == ["kicky", "snares"]
            # Each /dirt/registerSample carries (name, abs_path).
            kicky = only(filter(m -> m.args[1] == "kicky", register_msgs))
            @test endswith(kicky.args[2], "/curated/kicks/heavy_v3.wav")
            @test isabspath(kicky.args[2])
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset "[samples].roots still sends /dirt/loadSampleFolder (back-compat)" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            # Existing `withsamples` fixture has just `roots = ["./samples"]`.
            m = Ressac.parse_manifest(joinpath(@__DIR__, "fixtures", "plugins", "withsamples"))
            h = Ressac.get_section_handler(:samples)
            h(m.dir, m.sections["samples"], m.name)

            addrs = [Ressac.decode_message(b).address for b in mock.sent]
            @test "/dirt/loadSampleFolder" in addrs
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -6`
Expected: `sample_info(:kicky)` returns `nothing`; new test fails.

- [ ] **Step 3: Rewrite _handle_samples**

In `src/plugin_handlers.jl`, replace the entire body of `_handle_samples` with:

```julia
function _handle_samples(plugin_dir, data, plugin_name)
    sched = _LIVE_SCHEDULER[]
    if sched === nothing
        @error "plugin '$plugin_name' [samples]: no active session — cannot load samples"
        return nothing
    end

    metadata = get(data, "metadata", Dict{String,Any}())
    metadata isa AbstractDict ||
        throw(ArgumentError("plugin '$plugin_name' [samples.metadata] must be a table"))

    # Handle `roots = [...]` — back-compat with sub-project 1.
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
        send_osc(sched.osc, encode(OSCMessage("/dirt/loadSampleFolder", Any[path])))
        # Also register each subfolder as a SampleEntry so :samples can
        # list them.
        for sub in readdir(path; join=false)
            sub_path = joinpath(path, sub)
            isdir(sub_path) || continue
            variants = _audio_files_in(sub_path)
            isempty(variants) && continue
            meta = get(metadata, sub, Dict{String,Any}())
            register_sample!(SampleEntry(Symbol(sub), plugin_name,
                                         abspath(sub_path), variants, meta))
        end
    end

    # Handle `[samples.bank]` — the new aliasing/multi-bank API.
    bank = get(data, "bank", Dict{String,Any}())
    bank isa AbstractDict ||
        throw(ArgumentError("plugin '$plugin_name' [samples.bank] must be a table"))
    for (name, rel) in bank
        path = isabspath(rel) ? rel : joinpath(plugin_dir, rel)
        path = abspath(path)
        variants = if isfile(path)
            [path]
        elseif isdir(path)
            _audio_files_in(path)
        else
            @error "plugin '$plugin_name' [samples.bank]: '$name' path '$path' not found"
            continue
        end
        if isempty(variants)
            @error "plugin '$plugin_name' [samples.bank]: '$name' has no audio files at '$path'"
            continue
        end
        meta = get(metadata, name, Dict{String,Any}())
        register_sample!(SampleEntry(Symbol(name), plugin_name, path, variants, meta))
        send_osc(sched.osc, encode(OSCMessage("/dirt/registerSample", Any[String(name), path])))
    end

    return nothing
end
```

Important notes:
- The existing `register_section_handler!(:samples, _handle_samples)` line at the bottom of `plugin_handlers.jl` already wires this method into the registry; no re-registration needed.
- We read `metadata` once at the top so both `roots` and `bank` paths can pull from the same source.

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass; count rises.

- [ ] **Step 5: Commit**

```bash
git add src/plugin_handlers.jl test/test_plugin_handlers.jl
git commit -m "plugin_handlers: [samples.bank] + metadata + registry population"
```

---

## Task 5: K key — preview-under-cursor

**Files:**
- Modify: `src/tui_bindings.jl`
- Modify: `test/test_tui_bindings.jl`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_tui_bindings.jl` inside `@testset "tui_bindings"`:

```julia
    @testset "normal K previews sample under cursor" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            Ressac.register_sample!(Ressac.SampleEntry(:kicky, "p",
                "/tmp/k.wav", ["/tmp/k.wav"], Dict{String,Any}()))
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["@d1 p\"kicky sn\""]
            m.cursor_row = 1
            m.cursor_col = 9  # first letter of `kicky`
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key("K"))

            play = [Ressac.decode_message(b) for b in mock.sent
                    if Ressac.decode_message(b).address == "/dirt/play"]
            @test length(play) == 1
            @test play[1].args == Any["s", "kicky"]
            @test any(l -> occursin("preview kicky", l), m.logs)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset "K with :N suffix sends n parameter" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            Ressac.register_sample!(Ressac.SampleEntry(:snares, "p",
                "/tmp/snares", ["/tmp/s1.wav", "/tmp/s2.wav"], Dict{String,Any}()))
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["snares:1"]
            m.cursor_row = 1
            m.cursor_col = 1
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key("K"))

            play = [Ressac.decode_message(b) for b in mock.sent
                    if Ressac.decode_message(b).address == "/dirt/play"]
            @test length(play) == 1
            @test play[1].args == Any["s", "snares", "n", Int32(1)]
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset "K on unknown sample logs WARN, no OSC sent" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        mock = MockOSCClient()
        sched = Scheduler(mock; cps=0.5)
        Ressac._LIVE_SCHEDULER[] = sched
        try
            m = Ressac.LiveModel(; scheduler=sched)
            m.buffer = ["whatever"]
            m.cursor_row = 1
            m.cursor_col = 1
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key("K"))
            @test isempty(mock.sent)
            @test any(l -> occursin("no sample", l), m.logs)
        finally
            Ressac._LIVE_SCHEDULER[] = nothing
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5`
Expected: `K` is unhandled, no `/dirt/play` sent.

- [ ] **Step 3: Add the K handler**

In `src/tui_bindings.jl`, find the `elseif code == "G"` block inside `_handle_normal!` and add a new branch immediately AFTER the `elseif code == "g"` block (the `:g` chord setup), before any other letter handling. Actually a cleaner place is alongside the other letter actions — find `elseif code == "m"` (mute toggle) and add `K` right after the `m` branch:

```julia
    elseif code == "m"
        _toggle_mute!(m)
    elseif code == "K"
        _preview_under_cursor!(m)
```

Then append a new helper at the bottom of `src/tui_bindings.jl`, just before the file's last lines (after `_execute_ex_command!`):

```julia
const _WORD_RX = r"([A-Za-z_][\w]*)(?::(\d+))?"

"""
    _preview_under_cursor!(m::LiveModel)

Identify the sample name under the cursor (matches `name` or `name:N`),
look it up in the sample registry, and ship a one-shot `/dirt/play`
OSC bundle through the active scheduler's client. Logs `[INFO] preview …`
on success or `[WARN] no sample '…' loaded` on miss.
"""
function _preview_under_cursor!(m::LiveModel)
    line = m.buffer[m.cursor_row]
    isempty(line) && return
    # Extract the maximal word (letters/digits/underscore/colon) around
    # the cursor's column position.
    col = clamp(m.cursor_col, 1, lastindex(line) + 1)
    # Walk backwards to find the start.
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
        _push_log!(m, "[WARN] no sample '$word' loaded")
        return
    end
    name = Symbol(mt.captures[1])
    variant = mt.captures[2] === nothing ? 0 : parse(Int, mt.captures[2])

    entry = sample_info(name)
    if entry === nothing
        _push_log!(m, "[WARN] no sample '$(mt.captures[1])' loaded")
        return
    end

    sched = _LIVE_SCHEDULER[]
    if sched === nothing
        _push_log!(m, "[ERROR] preview: no active session")
        return
    end
    args = variant == 0 ?
        Any["s", String(name)] :
        Any["s", String(name), "n", Int32(variant)]
    send_osc(sched.osc, encode(OSCMessage("/dirt/play", args)))
    _push_log!(m, "[INFO] preview $(mt.captures[1])$(variant == 0 ? "" : ":$variant")")
end

_is_word_char(c::AbstractChar) = isletter(c) || isdigit(c) || c == '_' || c == ':'
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/tui_bindings.jl test/test_tui_bindings.jl
git commit -m "tui: K previews sample-under-cursor via /dirt/play one-shot"
```

---

## Task 6: `:samples` ex-command

**Files:**
- Modify: `src/tui_bindings.jl`
- Modify: `test/test_tui_bindings.jl`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_tui_bindings.jl`:

```julia
    @testset ":samples lists all loaded sample banks" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        try
            Ressac.register_sample!(Ressac.SampleEntry(:bd, "core",
                "/c/bd", ["/c/bd/a.wav"], Dict{String,Any}()))
            Ressac.register_sample!(Ressac.SampleEntry(:kicky, "funkit",
                "/f/k.wav", ["/f/k.wav"],
                Dict("bpm" => 120, "tags" => ["heavy"])))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key(":"))
            for c in "samples"
                Ressac._dispatch_key!(m, _fake_key(string(c)))
            end
            Ressac._dispatch_key!(m, _fake_key("Enter"))
            logs = join(m.logs, "\n")
            @test occursin("bd", logs)
            @test occursin("kicky", logs)
            @test occursin("funkit", logs)
            @test occursin("120 BPM", logs) || occursin("120", logs)
        finally
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset ":samples <glob> filters" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        try
            Ressac.register_sample!(Ressac.SampleEntry(:bd, "p",
                "/x", ["/x"], Dict{String,Any}()))
            Ressac.register_sample!(Ressac.SampleEntry(:bd2, "p",
                "/y", ["/y"], Dict{String,Any}()))
            Ressac.register_sample!(Ressac.SampleEntry(:sn, "p",
                "/z", ["/z"], Dict{String,Any}()))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key(":"))
            for c in "samples bd*"
                Ressac._dispatch_key!(m, _fake_key(string(c)))
            end
            Ressac._dispatch_key!(m, _fake_key("Enter"))
            logs = join(m.logs, "\n")
            @test occursin("bd", logs)
            @test occursin("bd2", logs)
            @test !occursin(r"\bsn\b", logs)
        finally
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end

    @testset ":samples <name> shows metadata detail" begin
        empty!(Ressac._SAMPLE_REGISTRY)
        try
            Ressac.register_sample!(Ressac.SampleEntry(:kicky, "funkit",
                "/k.wav", ["/k.wav"],
                Dict("bpm" => 120, "key" => "C", "tags" => ["heavy"])))
            m = Ressac.LiveModel(; scheduler=Scheduler(MockOSCClient(); cps=0.5))
            m.mode = :normal
            Ressac._dispatch_key!(m, _fake_key(":"))
            for c in "samples kicky"
                Ressac._dispatch_key!(m, _fake_key(string(c)))
            end
            Ressac._dispatch_key!(m, _fake_key("Enter"))
            logs = join(m.logs, "\n")
            @test occursin("kicky", logs)
            @test occursin("bpm", lowercase(logs)) || occursin("BPM", logs)
            @test occursin("heavy", logs)
        finally
            empty!(Ressac._SAMPLE_REGISTRY)
        end
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -6`
Expected: `:samples` unknown command, logs ERROR.

- [ ] **Step 3: Wire the ex-command**

In `src/tui_bindings.jl`, find `_execute_ex_command!` and add a new branch.
The current function reads:

```julia
function _execute_ex_command!(m::LiveModel, body::AbstractString)
    body = strip(body)
    if body == "q" || body == "quit"
        m.quit = true
    elseif startswith(body, "cps ")
        ...
    elseif (mt = match(r"^goto\s+d(\d+)$", body)) !== nothing
        _goto_slot!(m, parse(Int, mt.captures[1]))
    else
        _push_log!(m, "[ERROR] unknown command: $body")
    end
end
```

Add a `samples` branch BEFORE the `else`:

```julia
    elseif body == "samples" || startswith(body, "samples ")
        rest = strip(body == "samples" ? "" : body[9:end])
        _execute_samples_command!(m, rest)
```

Then append the helper at the bottom of `src/tui_bindings.jl`:

```julia
"""
    _execute_samples_command!(m, arg)

Handle the `:samples [arg]` ex-command:
- empty `arg`            → list all registered sample banks, grouped by plugin
- `arg` containing `*`/`?` (glob) → list banks whose name matches the glob
- otherwise              → show full metadata for the bank named `arg`
"""
function _execute_samples_command!(m::LiveModel, arg::AbstractString)
    if isempty(arg)
        _list_samples_to_log!(m, list_samples(r""))
        return
    end
    if occursin('*', arg) || occursin('?', arg)
        rx = Regex("^" * replace(replace(arg, "*" => ".*"), "?" => ".") * "\$")
        _list_samples_to_log!(m, list_samples(rx))
        return
    end
    entry = sample_info(Symbol(arg))
    if entry === nothing
        _push_log!(m, "[WARN] no sample '$arg' loaded")
        return
    end
    _push_log!(m, "[$(entry.plugin)] $(entry.name): $(length(entry.variants)) variant(s)")
    _push_log!(m, "  path: $(entry.bank_path)")
    for (k, v) in entry.metadata
        _push_log!(m, "  $k: $v")
    end
end

function _list_samples_to_log!(m::LiveModel, entries)
    if isempty(entries)
        _push_log!(m, "(no samples loaded)")
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
        bpm = get(e.metadata, "bpm", nothing)
        bpm_str = bpm === nothing ? "" : "  $(bpm) BPM"
        _push_log!(m, "  $(e.name)  $(length(e.variants))v$tag_str$bpm_str")
    end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/tui_bindings.jl test/test_tui_bindings.jl
git commit -m "tui: :samples ex-command (list, glob filter, metadata detail)"
```

---

## Task 7: SuperDirt OSCdef for /dirt/registerSample

**Files:**
- Modify: `scripts/superdirt-startup.scd`

This task is SC-side only — Julia tests already covered the OSC payload
format in Task 4. We're just wiring the receiver.

- [ ] **Step 1: Baseline test run**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 2: Append the OSCdef**

In `scripts/superdirt-startup.scd`, find the `OSCdef(\ressacEvalSC, …)` block and add a new OSCdef immediately after it (before the final closing block of log messages):

```supercollider
    OSCdef(\ressacRegisterSample, { |msg|
        var name = msg[1].asString.asSymbol;
        var path = msg[2].asString;
        ("[ressac] registerSample " ++ name ++ " ← " ++ path).postln;
        if(File.exists(path)) {
            // For directories, defer to SuperDirt's loader (it indexes
            // by parent dir name; SuperDirt picks up the new buffers
            // under `name` automatically).
            if(PathName(path).isFolder) {
                ~dirt.loadSoundFiles(path ++ "/*");
            } {
                // Single-file bank: build one Buffer, install under `name`.
                var buf = Buffer.read(~dirt.server, path);
                ~dirt.soundLibrary.addBuffer(name, buf);
            };
        } {
            ("[ressac] registerSample: missing path " ++ path).warn;
        };
    }, '/dirt/registerSample');
```

Update the banner output near the bottom to mention the new responder:

```supercollider
    "Ressac OSC responders installed: /dirt/loadSampleFolder, /dirt/evalSC, /dirt/registerSample".postln;
```

- [ ] **Step 3: Sanity-check via just (manual, optional)**

Run: `just audio` in a separate terminal if available. Look for the
updated banner mentioning `/dirt/registerSample`. Ctrl+C to stop.

- [ ] **Step 4: Final test run**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/superdirt-startup.scd
git commit -m "superdirt: OSCdef /dirt/registerSample for aliased banks"
```

---

## Task 8: Update cheatsheet

**Files:**
- Modify: `docs/cheatsheet.md`

- [ ] **Step 1: Find the existing Plugins section**

Run: `grep -n '^## Plugins' docs/cheatsheet.md`
Expected: matches line ~185 (or wherever the section starts after the previous sub-project).

- [ ] **Step 2: Extend the Plugins section**

In `docs/cheatsheet.md`, find the `[samples]` manifest example inside the "Plugins" section:

```toml
[samples]
roots = ["./samples"]
```

Replace it with the extended form:

```toml
[samples]
roots = ["./samples"]            # default load: subdir name → bank name

[samples.bank]                    # explicit aliases + multi-bank
kicky  = "./curated/heavy_v3.wav" # file → kicky:0
snares = "./curated/snares"        # dir  → snares:0,:1,:2…

[samples.metadata.kicky]
bpm  = 120
tags = ["heavy", "subby"]
```

Then add a new subsection "Sample bank workflow" just before "## Common gotchas":

````markdown
### Sample bank workflow

```
:samples                  # list all loaded banks, grouped by plugin
:samples bd*              # glob filter
:samples kicky            # full metadata of one bank
```

Position the cursor on any sample-like word (`kicky`, `snares:1`) in
normal mode and press `K` to play it once via `/dirt/play`, without
touching your slots. The variant suffix (`:N`) is honoured.

Inspect from the REPL:

```julia
julia> sample_info(:kicky)
julia> list_samples(r"^bd")
```

````

- [ ] **Step 3: Commit**

```bash
git add docs/cheatsheet.md
git commit -m "docs: cheatsheet — [samples.bank], :samples, K preview"
```

---

## Task 9: Exports + precompile workload

**Files:**
- Modify: `src/Ressac.jl`

- [ ] **Step 1: Add exports**

In `src/Ressac.jl`, find the plugin-exports line and extend:

```julia
export register_section_handler!, unregister_section_handler!, get_section_handler
export load_plugin, parse_manifest, discover_plugins, default_plugin_path
export SampleEntry, sample_info, list_samples, register_sample!
```

- [ ] **Step 2: Extend the precompile workload**

In the `@compile_workload begin … end` block, just after the existing
plugin precompile section, append:

```julia
    # Sample banks: parse the withbanks fixture and exercise the
    # registry helpers, so first-session preview/listing is cheap.
    bank_fixture = joinpath(@__DIR__, "..", "test", "fixtures", "plugins", "withbanks")
    if isfile(joinpath(bank_fixture, "plugin.toml"))
        try
            empty!(_SAMPLE_REGISTRY)
            mb = parse_manifest(bank_fixture)
            # Don't actually call the handler (it needs an active session);
            # just touch the registry path directly.
            register_sample!(SampleEntry(:_pc_kicky, "withbanks",
                joinpath(bank_fixture, "curated/kicks/heavy_v3.wav"),
                String[], Dict{String,Any}("bpm" => 120)))
            sample_info(:_pc_kicky)
            list_samples(r"_pc")
            empty!(_SAMPLE_REGISTRY)
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
git commit -m "plugins: export SampleEntry/sample_info/list_samples + precompile path"
```

---

## Self-review summary

Mapping spec → tasks:

- §3 manifest format (`[samples.bank]`, `[samples.metadata.*]`) → Tasks 3 (fixture) + 4 (handler rewrite).
- §4 Julia-side registry (`SampleEntry`, `_SAMPLE_REGISTRY`, `sample_info`, `list_samples`, `register_sample!`) → Task 1.
- §5 SuperDirt `/dirt/registerSample` OSCdef → Task 7. The OSC payload format is asserted by tests in Task 4 (Julia-side).
- §6 `K` preview-under-cursor → Task 5. `:samples` ex-command → Task 6.
- §7 file layout — reflected in this plan's top-level table.
- §8 test strategy — distributed across Tasks 1, 4, 5, 6. Every requirement has at least one test.
- §9 out of scope — no tasks (deliberately deferred).
- §10 migration — Task 4 keeps the `roots` back-compat path intact; the existing `withsamples` fixture exercises it.

Type-consistency check: `SampleEntry` fields used across tasks: `name::Symbol`, `plugin::String`, `bank_path::String`, `variants::Vector{String}`, `metadata::Dict{String,Any}`. All matching across Tasks 1, 4, 5, 6. `register_sample!`/`sample_info`/`list_samples` signatures match.

Placeholder scan: none. Every step has full code or full commands.
