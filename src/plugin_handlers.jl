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
