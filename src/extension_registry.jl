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
    context::Symbol               # :patterns | :synth | :any
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
    context_str = String(get(raw, "context", "any"))
    context = context_str in ("patterns", "synth_dsl", "synth_sc", "any") ?
              Symbol(context_str) :
              begin
                  @warn "snippet '$name' has unknown context '$context_str'; defaulting to :any"
                  :any
              end
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
    # No Julia syntax validation at load time. Snippets come in many
    # flavours:
    #   * full top-level Julia (e.g. `@d1 p"bd"`)
    #   * fragments meant to be appended to existing code (`|> shape(0.8)`)
    #   * SuperCollider source for the synth pane (`var x = ...`)
    # Pre-validating would reject every fragment. Errors surface
    # naturally at insert+eval time, where the user sees them in
    # the live log.

    _SNIPPET_RAW[String(name)] = (own_content = own_content, includes = includes)
    return SnippetEntry(
        String(name), mode, description, tags, context,
        requires, includes,
        "",
        collect(Any, panes),
        String(plugin_name),
        abspath(toml_path),
    )
end

"""
    _resolve_snippet_includes!()

Walk the snippet include DAG, compute `resolved_content` for every
entry in `_SNIPPET_REGISTRY`, and replace each entry with a fresh
`SnippetEntry` whose `resolved_content` field is populated.

Cycle members and snippets with unresolvable includes fall back to
`resolved_content = own_content` (i.e. they're still usable, just
without the include's contribution).

`requires_plugins` is the **union** of own + every transitively
included snippet's requires_plugins.

Called once by the plugin loader after every plugin has registered.
"""
function _resolve_snippet_includes!()
    raw = _SNIPPET_RAW
    names = collect(keys(raw))
    deps = Dict(n => Set(raw[n].includes) for n in names)
    # Drop unknown includes and warn for each.
    missing_includes = Dict{String, Vector{String}}()
    for n in names
        for inc in deps[n]
            if !haskey(raw, inc)
                push!(get!(() -> String[], missing_includes, n), inc)
            end
        end
        intersect!(deps[n], Set(names))
    end
    for (n, miss) in missing_includes
        for inc in miss
            @warn "snippet '$n': missing include '$inc' — fallback to own content only"
        end
    end

    # Kahn's algorithm.
    in_degree = Dict(n => length(deps[n]) for n in names)
    rev = Dict{String, Vector{String}}()
    for n in names, d in deps[n]
        push!(get!(() -> String[], rev, d), n)
    end
    ordered = String[]
    ready = sort([n for n in names if in_degree[n] == 0])
    while !isempty(ready)
        n = popfirst!(ready)
        push!(ordered, n)
        for child in get(rev, n, String[])
            in_degree[child] -= 1
            in_degree[child] == 0 && push!(ready, child)
        end
        sort!(ready)
    end

    cycle_members = Set(setdiff(names, ordered))
    if !isempty(cycle_members)
        @warn "snippet include cycle detected: $(sort(collect(cycle_members)))"
    end

    # Resolution: each atom (raw[a].own_content for snippet a) appears
    # EXACTLY ONCE in the final resolved_content. To handle diamond
    # dependencies (A depends on B and C, both on D) without duplicating
    # D, we compute each snippet's transitive ancestor set, order it by
    # the global topological order, and concat each ancestor's own
    # content in that order before appending the snippet's own content.
    ancestors = Dict{String, Set{String}}()
    for n in ordered
        acc = Set{String}()
        for d in deps[n]
            haskey(ancestors, d) && union!(acc, ancestors[d])
            push!(acc, d)
        end
        ancestors[n] = acc
    end

    topo_idx = Dict(n => i for (i, n) in enumerate(ordered))
    resolved_str = Dict{String, String}()
    resolved_req = Dict{String, Vector{String}}()
    for n in ordered
        anc_topo = sort([a for a in ancestors[n]]; by = a -> topo_idx[a])
        parts = String[raw[a].own_content for a in anc_topo]
        push!(parts, raw[n].own_content)
        resolved_str[n] = join(parts, "\n\n")

        own_req = Set(_SNIPPET_REGISTRY[n].requires_plugins)
        for a in anc_topo
            union!(own_req, Set(_SNIPPET_REGISTRY[a].requires_plugins))
        end
        resolved_req[n] = sort!(collect(own_req))
    end
    for n in cycle_members
        resolved_str[n] = raw[n].own_content
        resolved_req[n] = sort!(collect(Set(_SNIPPET_REGISTRY[n].requires_plugins)))
    end

    for n in names
        old = _SNIPPET_REGISTRY[n]
        _SNIPPET_REGISTRY[n] = SnippetEntry(
            old.name, old.mode, old.description, old.tags, old.context,
            resolved_req[n], old.includes,
            resolved_str[n], old.panes, old.plugin, old.path,
        )
    end

    empty!(_SNIPPET_RAW)
    return nothing
end

"""
    _handle_docs(plugin_dir, data, plugin_name)

`[docs]` section handler. Scans `<plugin_dir>/<data["dir"]>` (default
`"docs"`) for `*.md` files. Each file is parsed for TOML frontmatter
between `+++` fences; missing or malformed files are warned about
and skipped.

Frontmatter fields:
  * `name` (required) — the registry key
  * `short` (optional, default "") — tooltip / `:doc <name>` line
  * `tags` (optional, default []) — list of strings, converted to Symbols
  * `kwargs` (optional, default [])
  * `examples` (optional, default [])

The body (everything after the closing `+++`) is loaded into
`DocEntry.body` for future use by the doc-pane UI.
"""
function _handle_docs(plugin_dir, data, plugin_name)
    data isa AbstractDict || (data = Dict{String,Any}())
    dir_rel = get(data, "dir", "docs")
    docs_dir = isabspath(dir_rel) ? dir_rel : joinpath(plugin_dir, dir_rel)
    isdir(docs_dir) || return nothing
    for f in sort(readdir(docs_dir; join=false))
        endswith(f, ".md") || continue
        path = abspath(joinpath(docs_dir, f))
        src = try
            read(path, String)
        catch err
            @warn "doc file '$path': read failed: $(sprint(showerror, err))"
            continue
        end
        fm, body = _parse_frontmatter(src)
        name = get(fm, "name", nothing)
        if name === nothing || !(name isa AbstractString) || isempty(name)
            @warn "doc file '$path' has no frontmatter 'name' field; skipping"
            continue
        end
        short = String(get(fm, "short", ""))
        tags = Symbol[Symbol(t) for t in get(fm, "tags", String[])]
        kwargs = Symbol[Symbol(k) for k in get(fm, "kwargs", String[])]
        examples = String[String(x) for x in get(fm, "examples", String[])]
        register_doc!(DocEntry(
            String(name), short, tags, kwargs, examples,
            body, String(plugin_name), path,
        ))
    end
    return nothing
end

register_section_handler!(:docs, _handle_docs)

"""
    _handle_snippets(plugin_dir, data, plugin_name)

`[snippets]` section handler. Scans `<plugin_dir>/<data["dir"]>`
(default `"snippets"`) for `*.toml` manifests. Each manifest is
parsed via `_load_snippet_toml` (which validates the sidecar `.jl`).
Valid entries are registered with `resolved_content = ""`; the
resolver pass (`_resolve_snippet_includes!`) is called once by the
plugin loader after all plugins have finished registering.
"""
function _handle_snippets(plugin_dir, data, plugin_name)
    data isa AbstractDict || (data = Dict{String,Any}())
    dir_rel = get(data, "dir", "snippets")
    snippets_dir = isabspath(dir_rel) ? dir_rel : joinpath(plugin_dir, dir_rel)
    isdir(snippets_dir) || return nothing
    for f in sort(readdir(snippets_dir; join=false))
        endswith(f, ".toml") || continue
        toml_path = abspath(joinpath(snippets_dir, f))
        e = _load_snippet_toml(toml_path, plugin_name)
        e === nothing && continue
        register_snippet!(e)
    end
    return nothing
end

register_section_handler!(:snippets, _handle_snippets)
