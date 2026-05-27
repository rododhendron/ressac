# Extension registry — generic plugin-discoverable docs + snippets.
# See docs/journal/20260527_extension_registry_design.md for design.

using TOML

struct DocEntry
    name::String
    short::String
    tags::Vector{Symbol}
    kwargs::Vector{Symbol}
    examples::Vector{String}
    body::String          # raw MD body after frontmatter ("" if none)
    plugin::String        # source plugin name
    path::String          # absolute path to the source file
end

const _DOCS = Dict{String,DocEntry}()

"""
    register_doc!(entry::DocEntry) -> DocEntry

Register `entry` keyed by its `name`. Last-wins on conflicts between
plugins — a `@warn` is emitted naming both the new and old plugin so
the user can chase down a surprise override.
"""
function register_doc!(e::DocEntry)
    if haskey(_DOCS, e.name) && _DOCS[e.name].plugin != e.plugin
        @warn "doc '$(e.name)' shadowed by plugin '$(e.plugin)' " *
              "(previously from '$(_DOCS[e.name].plugin)')"
    end
    _DOCS[e.name] = e
    return e
end

"""
    lookup_doc(name) -> Union{DocEntry,Nothing}
"""
lookup_doc(name::AbstractString) = get(_DOCS, String(name), nothing)

"""
    list_docs() -> Vector{String}

Names of every registered doc, sorted ascending.
"""
list_docs() = sort!(collect(keys(_DOCS)))
