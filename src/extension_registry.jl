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

"""
    _parse_frontmatter(src::AbstractString) -> (Dict, String)

Parse Hugo-style TOML frontmatter between `+++` fences at the start of
`src`. Returns `(frontmatter_dict, body)`. If no frontmatter present,
returns `(empty Dict, src unchanged)`. If the opening fence has no
closing fence, logs a warning and returns `(empty Dict, src unchanged)`.

Whitespace before the opening fence is permitted; the fence line
itself must be exactly `+++` (optional trailing whitespace stripped).
"""
function _parse_frontmatter(src::AbstractString)
    lines = split(src, '\n')
    i = 1
    while i <= length(lines) && isempty(strip(lines[i]))
        i += 1
    end
    if i > length(lines) || strip(lines[i]) != "+++"
        return (Dict{String,Any}(), String(src))
    end
    j = i + 1
    while j <= length(lines) && strip(lines[j]) != "+++"
        j += 1
    end
    if j > length(lines)
        @warn "unterminated frontmatter (opening +++ at line $i has no closing fence)"
        return (Dict{String,Any}(), String(src))
    end
    fm_text = join(lines[i+1:j-1], "\n")
    fm = try
        TOML.parse(fm_text)
    catch err
        @warn "invalid TOML frontmatter: $(sprint(showerror, err))"
        Dict{String,Any}()
    end
    body = j+1 <= length(lines) ? join(lines[j+1:end], "\n") : ""
    # Strip a single leading blank line so body's first non-blank line
    # is what the reader sees first.
    if !isempty(body) && lines[j+1] == ""
        body = j+2 <= length(lines) ? join(lines[j+2:end], "\n") : ""
    end
    return (fm, body)
end

# Bookkeeping for the resolver: between registration and resolution, we
# need to remember each snippet's own_content + raw includes. We stash
# them in a parallel dict keyed by snippet name. The resolver consumes
# this dict, computes resolved_content, and clears the dict.
const _SNIPPET_RAW = Dict{String, NamedTuple{(:own_content, :includes), Tuple{String, Vector{String}}}}()

"""
    _load_snippet_toml(toml_path, plugin_name) -> Union{SnippetEntry, Nothing}

Read a snippet manifest TOML at `toml_path`. Resolves `content_file`
relative to the TOML's directory. Validates the sidecar parses as
Julia. Builds a `SnippetEntry` with `resolved_content = ""` (filled
later by the resolver). Stashes the raw own-content + declared
includes in `_SNIPPET_RAW` for the resolver to consume.

Returns `nothing` and logs a warning if:
  * The manifest TOML is malformed
  * `content_file` is missing or unreadable
  * The sidecar fails `Meta.parse` with a `:error` head
"""
function _load_snippet_toml(toml_path::AbstractString, plugin_name::AbstractString)
    raw = try
        TOML.parsefile(toml_path)
    catch err
        @warn "snippet manifest '$toml_path': TOML parse failed: $(sprint(showerror, err))"
        return nothing
    end
    name = get(raw, "name", nothing)
    if name === nothing || !(name isa AbstractString) || isempty(name)
        @warn "snippet manifest '$toml_path' missing or invalid 'name' field"
        return nothing
    end
    mode_str = get(raw, "mode", "block")
    mode = mode_str == "starter" ? :starter :
           mode_str == "block"   ? :block   :
           begin
               @warn "snippet '$name' has unknown mode '$mode_str'; defaulting to :block"
               :block
           end
    description = String(get(raw, "description", ""))
    tags = Symbol[Symbol(t) for t in get(raw, "tags", String[])]
    requires = String[String(p) for p in get(raw, "requires_plugins", String[])]
    includes = String[String(i) for i in get(raw, "includes", String[])]
    panes = get(raw, "panes", Any[])
    panes isa AbstractVector || (panes = Any[])

    content_file = get(raw, "content_file", "")
    if isempty(content_file)
        @warn "snippet '$name' at '$toml_path' has no content_file"
        return nothing
    end
    sidecar_path = joinpath(dirname(toml_path), content_file)
    if !isfile(sidecar_path)
        @warn "snippet '$name': sidecar '$content_file' not found at '$sidecar_path'"
        return nothing
    end
    own_content = try
        read(sidecar_path, String)
    catch err
        @warn "snippet '$name': sidecar read failed: $(sprint(showerror, err))"
        return nothing
    end
    parsed = Meta.parse("begin\n$own_content\nend"; raise=false)
    if parsed isa Expr && parsed.head === :error
        @warn "snippet '$name': sidecar has Julia syntax error — skipping"
        return nothing
    end

    _SNIPPET_RAW[String(name)] = (own_content = own_content, includes = includes)
    return SnippetEntry(
        String(name), mode, description, tags,
        requires, includes,
        "",
        collect(Any, panes),
        String(plugin_name),
        abspath(toml_path),
    )
end
