# Built-in section handlers for `[samples]`, `[synthdefs]`, `[julia]`.
# Each is registered at module load time via `register_section_handler!`
# so external plugins use the exact same extension mechanism.

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
