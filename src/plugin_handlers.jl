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
        path = isabspath(r) ? r : joinpath(plugin_dir, r)
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

register_section_handler!(:samples, _handle_samples)

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
