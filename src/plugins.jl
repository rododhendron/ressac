# Plugin registry, manifest parsing, search-path discovery, and load
# orchestration. Built-in section handlers live in `plugin_handlers.jl`
# and register themselves through the public API defined here.

using TOML

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
    seen = Dict{String,String}()
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
    remaining_deps = Dict(m.name => Set{String}(filter(d -> haskey(by_name, d), m.depends_on)) for m in valid)
    out = PluginManifest[]
    order = Dict(m.name => i for (i, m) in enumerate(valid))
    while !isempty(remaining_deps)
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
