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

struct SnippetEntry
    name::String
    mode::Symbol                  # :starter or :block
    description::String
    tags::Vector{Symbol}
    requires_plugins::Vector{String}   # transitive union after resolution
    includes::Vector{String}           # raw declared includes (for debug)
    resolved_content::String           # final Julia source ready to apply
    panes::Vector{Any}                 # future UI hints, parsed but unused
    plugin::String
    path::String                       # path to the TOML manifest
end

const _SNIPPET_REGISTRY = Dict{String,SnippetEntry}()

"""
    register_snippet!(entry::SnippetEntry) -> SnippetEntry

Register `entry` keyed by its `name`. Last-wins on conflicts between
plugins, with a `@warn`.

The resolved_content field may be `""` at registration time; it gets
populated by `_resolve_snippet_includes!()` after all plugins have
registered (called once by the plugin loader).
"""
function register_snippet!(e::SnippetEntry)
    if haskey(_SNIPPET_REGISTRY, e.name) && _SNIPPET_REGISTRY[e.name].plugin != e.plugin
        @warn "snippet '$(e.name)' shadowed by plugin '$(e.plugin)' " *
              "(previously from '$(_SNIPPET_REGISTRY[e.name].plugin)')"
    end
    _SNIPPET_REGISTRY[e.name] = e
    return e
end

"""
    lookup_snippet(name) -> Union{SnippetEntry,Nothing}
"""
lookup_snippet(name::AbstractString) = get(_SNIPPET_REGISTRY, String(name), nothing)

"""
    list_snippets() -> Vector{String}

Every registered snippet name, sorted ascending.
"""
list_snippets() = sort!(collect(keys(_SNIPPET_REGISTRY)))

"""
    list_starters() -> Vector{String}

Names of snippets with `mode === :starter`, sorted ascending. Used
by `:starter <Tab>` completion.
"""
list_starters() = sort!([k for (k, v) in _SNIPPET_REGISTRY if v.mode === :starter])
