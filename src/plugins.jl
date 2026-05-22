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
