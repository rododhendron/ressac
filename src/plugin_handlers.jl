# Built-in section handlers for `[samples]`, `[synthdefs]`, `[julia]`.
# Each is registered at module load time via `register_section_handler!`
# so external plugins use the exact same extension mechanism.

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

"""
    _expand_path(p) -> String

Expand `~` and `\$VAR` / `\${VAR}` references in a path. Used by the
`[samples]` handler so manifest authors can point at locations defined
by their environment (e.g. `\$DIRT_SAMPLES_PATH` from the Nix flake).

Unknown vars expand to empty (matching shell behaviour); `~` resolves
via `homedir()`. Plain paths pass through unchanged.
"""
function _expand_path(p::AbstractString)
    s = String(p)
    s = startswith(s, "~/") ? joinpath(homedir(), s[3:end]) : s
    s = s == "~" ? homedir() : s
    # Replace ${VAR} first, then $VAR.
    s = replace(s, r"\$\{(\w+)\}" => sub -> get(ENV, sub[3:end-1], ""))
    s = replace(s, r"\$(\w+)" => sub -> get(ENV, sub[2:end], ""))
    return s
end

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
_osc_value(v::Symbol) = String(v)
function _osc_value(v)
    @warn "unsupported OSC value of type $(typeof(v)); dropping"
    return missing
end

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

register_section_handler!(:julia, _handle_julia)

"""
    _handle_samples(plugin_dir, section_data, plugin_name)

Process `[samples]`: a multi-shape section that may contain any of
`roots`, `bank`, and `metadata`. Backward-compatible with sub-project 1's
roots-only manifests.

- `roots = [...]`: scan each path's subdirectories the SuperDirt way
  (subdir name → bank name). Ships `/dirt/loadSampleFolder` per root
  AND registers each subdir as a SampleEntry so introspection works.

- `[samples.bank]`: explicit mapping of bank-name → file-or-dir path.
  File path → 1-variant bank; dir path → multi-variant bank (sorted).
  Ships `/dirt/registerSample <name> <path>` per entry and registers a
  SampleEntry.

- `[samples.metadata.<bank>]`: optional per-bank metadata attached to
  the SampleEntry. Same key is used for both roots-derived and bank-
  derived entries.

Errors are logged; processing continues with the next root/entry.
"""
function _handle_samples(plugin_dir, data, plugin_name)
    sched = _LIVE_SCHEDULER[]
    if sched === nothing
        @error "plugin '$plugin_name' [samples]: no active session — cannot load samples"
        return nothing
    end

    metadata = get(data, "metadata", Dict{String,Any}())
    metadata isa AbstractDict ||
        throw(ArgumentError("plugin '$plugin_name' [samples.metadata] must be a table"))

    # Back-compat: `roots = [...]`.
    roots = get(data, "roots", String[])
    roots isa AbstractVector ||
        throw(ArgumentError("plugin '$plugin_name' [samples] roots must be an array"))
    for r in roots
        r_expanded = _expand_path(r)
        path = isabspath(r_expanded) ? r_expanded : joinpath(plugin_dir, r_expanded)
        path = abspath(path)
        if !isdir(path)
            @error "plugin '$plugin_name' [samples]: path '$path' not found"
            continue
        end
        send_osc(sched.osc, encode(OSCMessage("/dirt/loadSampleFolder", Any[path])))
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

    # New: `[samples.bank]`.
    bank = get(data, "bank", Dict{String,Any}())
    bank isa AbstractDict ||
        throw(ArgumentError("plugin '$plugin_name' [samples.bank] must be a table"))
    for (name, rel) in bank
        rel_expanded = _expand_path(rel)
        path = isabspath(rel_expanded) ? rel_expanded : joinpath(plugin_dir, rel_expanded)
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

register_section_handler!(:samples, _handle_samples)

"""
    _handle_synthdefs(plugin_dir, section_data, plugin_name)

Load every SynthDef this plugin owns. Two sources:

  1. **Manifested** — `[synthdefs] files = ["./synth.scd", ...]`.
     Listed paths are honoured in declaration order.

  2. **Orphan auto-discovery** — any `.scd` / `.jl` file in
     `plugin_dir` that wasn't named in `files`. This is what makes
     `:lib → instantiate` and `:save-synth` work robustly: the
     manifest can be incomplete (or absent) and the user's synths
     still load on next boot. The single source of truth becomes
     "what's on disk", not "what the manifest remembered to track".

For each file:
  * `.scd` → ship the source via `/dirt/evalSC` (SC interprets it)
            and register a `SynthEntry(plugin = "user-synths")` so
            `_is_user_synth` recognises pattern events targeting it.
  * `.jl`  → `Core.eval` it into the Ressac module. These are DSL
            files written with `@synth :name …`; the macro itself
            ships the SynthDef + registers as `"user-dsl"`.

Errors: missing manifested file → `@error`, continue; absent session
→ `@error`, abort. Eval / read failures on orphans are logged but
don't stop other files from loading.
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

    loaded_abs = Set{String}()
    for f in files
        path = isabspath(f) ? f : joinpath(plugin_dir, f)
        if !isfile(path)
            @error "plugin '$plugin_name' [synthdefs]: no such file '$path'"
            continue
        end
        _load_synth_file!(sched, plugin_name, path)
        push!(loaded_abs, abspath(path))
    end

    # Orphan auto-discovery: glob the plugin dir for any .scd / .jl
    # we haven't already processed. Guarded by two checks:
    #   1. `plugin_dir` must contain a plugin.toml — defends against
    #      callers passing synthetic paths like /tmp (the synthdefs
    #      handler tests do this), which would otherwise glob the
    #      caller's whole tmp dir and eval arbitrary files.
    #   2. Each candidate file must pass `_looks_like_synth_source`
    #      (header sniff for SynthDef / @synth) — defends against
    #      a real plugin dir containing stray .jl files that happen
    #      to live alongside actual synthdefs.
    # Quiet success: only log when something is loaded.
    isdir(plugin_dir) || return nothing
    isfile(joinpath(plugin_dir, "plugin.toml")) || return nothing
    orphans = String[]
    for f in sort(readdir(plugin_dir))
        ext = splitext(f)[2]
        ext in (".scd", ".jl") || continue
        path = abspath(joinpath(plugin_dir, f))
        path in loaded_abs && continue
        _looks_like_synth_source(path) || continue
        push!(orphans, path)
    end
    isempty(orphans) && return nothing
    for path in orphans
        _load_synth_file!(sched, plugin_name, path)
    end
    @info "plugin '$plugin_name': auto-loaded $(length(orphans)) orphan synth file(s) not in manifest"
    return nothing
end

"""
    _looks_like_synth_source(path) -> Bool

Quick header sniff to decide whether a file is plausibly a synth
definition. `.scd` must contain `SynthDef(`; `.jl` must contain
`@synth`. Cheaper than a full parse and good enough to skip random
text / config files that happen to share an extension with synth
sources. Read failure → false (we don't auto-load what we can't see).
"""
function _looks_like_synth_source(path::AbstractString)
    ext = splitext(path)[2]
    needle = ext == ".scd" ? "SynthDef(" :
             ext == ".jl"  ? "@synth"    : return false
    src = try
        read(path, String)
    catch
        return false
    end
    return occursin(needle, src)
end

"""
    _load_synth_file!(sched, plugin_name, path)

Load one SynthDef source file. Dispatches on extension:

  * `.scd` — ship the source via `/dirt/evalSC`. Only registers a
    fallback SynthEntry if the metadata layer (`[synths.<name>]`
    block in the plugin manifest) didn't already register one;
    otherwise the manifest's richer metadata wins (and same-plugin
    re-register would otherwise emit a spurious shadow warning).
  * `.jl` — DSL source. Loaded with `Base.include` into the
    `SynthDSL` submodule so `@synth`, `saw`, `pulse`, etc. resolve
    natively. `Base.include` also threads `__source__.file = path`
    so the macro can derive the SC name from the filename when
    no explicit alias is given.
"""
function _load_synth_file!(sched, plugin_name, path)
    ext = splitext(path)[2]
    name = Symbol(splitext(basename(path))[1])
    if ext == ".scd"
        src = try
            read(path, String)
        catch err
            @error "plugin '$plugin_name' [synthdefs]: read failed for '$path': $(sprint(showerror, err))"
            return
        end
        send_osc(sched.osc, encode(OSCMessage("/dirt/evalSC", Any[src])))
        # Only register if no SynthEntry already exists. The
        # `[synths.<name>]` block in plugin.toml is the authoritative
        # metadata source — don't shadow it with our minimal entry.
        if synth_info(name) === nothing
            register_synth!(SynthEntry(name, plugin_name, Dict{String,Any}(
                "description" => "loaded from $(basename(path))",
                "tags"        => ["user"],
            )))
        end
    elseif ext == ".jl"
        try
            Base.include(SynthDSL, path)
        catch err
            @error "plugin '$plugin_name' [synthdefs]: .jl eval failed for '$path': $(sprint(showerror, err))"
        end
    end
end

register_section_handler!(:synthdefs, _handle_synthdefs)

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

"""
    _handle_synths(plugin_dir, data, plugin_name)

Parse `[synths.<name>]` sub-tables. A synth entry is purely descriptive —
all keys (`tags`, `description`, anything else) are stuffed into metadata.
The actual synthdef is defined via `[synthdefs]`; `[synths]` is the
introspection layer.
"""
function _handle_synths(plugin_dir, data, plugin_name)
    data isa AbstractDict ||
        throw(ArgumentError("plugin '$plugin_name' [synths] must be a table"))
    for (name, body) in data
        body isa AbstractDict || begin
            @error "plugin '$plugin_name' [synths.$name] must be a table"
            continue
        end
        metadata = Dict{String,Any}(string(k) => v for (k, v) in body)
        register_synth!(SynthEntry(Symbol(name), plugin_name, metadata))
    end
    return nothing
end

register_section_handler!(:synths, _handle_synths)
