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
