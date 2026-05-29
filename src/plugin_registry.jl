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

"""
    load_plugin(manifest::PluginManifest)

Run each section's handler from `manifest.sections`. The `[julia]`
section, if present, runs first inside this plugin (so any
`register_section_handler!` calls it makes are visible to subsequent
sections of the same plugin).

Unknown sections log a warning. Handler exceptions are caught and
logged at `@error` level; the next section still runs.
"""
function load_plugin(m::PluginManifest)
    section_names = collect(keys(m.sections))
    if "julia" in section_names
        section_names = vcat("julia", filter(!=("julia"), section_names))
    end
    for sec_str in section_names
        sec = Symbol(sec_str)
        h = get_section_handler(sec)
        if h === nothing
            @warn "no handler registered for section ':$sec_str' (in plugin '$(m.name)'); skipping"
            continue
        end
        try
            h(m.dir, m.sections[sec_str], m.name)
        catch err
            @error "handler ':$sec_str' for plugin '$(m.name)' raised: $(sprint(showerror, err))"
        end
    end
    return nothing
end

"""
    default_plugin_path() -> Vector{String}

Plugin search path used by default at session start. Order:
1. `\$PWD/plugins`                        — project tree
2. `~/.config/ressac/plugins`             — user overrides
3. `~/.cache/ressac/plugins`              — auto-generated (e.g. sc-autodiscover)
4. Entries from `\$RESSAC_PLUGIN_PATH` (`:`-separated).

The cache path is third so user overrides (config) win over the
auto-generated content via the registry's last-wins on conflict.

Non-existent entries are kept in the list and silently skipped by
`discover_plugins`.
"""
function default_plugin_path()
    path = String[joinpath(pwd(), "plugins")]
    push!(path, joinpath(homedir(), ".config", "ressac", "plugins"))
    push!(path, joinpath(homedir(), ".cache",  "ressac", "plugins"))
    extra = get(ENV, "RESSAC_PLUGIN_PATH", "")
    if !isempty(extra)
        for entry in split(extra, ':')
            isempty(entry) || push!(path, String(entry))
        end
    end
    return path
end

"""
    _load_plugins(path = default_plugin_path())

Discover, topo-sort, and load every plugin on the search `path`. Used
internally by `start_live!`; exposed for tests.
"""
function _load_plugins(path::AbstractVector{<:AbstractString} = default_plugin_path())
    manifests = discover_plugins(path)
    ordered = topo_sort(manifests)
    # Core-first reordering: pluck `core` out (if present) and put it at
    # the head. Preserves topo order for everything else. Lets a user
    # plugin override a core doc/snippet via last-wins registration.
    core_idx = findfirst(m -> m.name == "core", ordered)
    if core_idx !== nothing && core_idx != 1
        core = ordered[core_idx]
        deleteat!(ordered, core_idx)
        pushfirst!(ordered, core)
    end
    for m in ordered
        try
            load_plugin(m)
            @info "loaded plugin: $(m.name) $(m.version)"
        catch err
            @error "plugin '$(m.name)' failed to load: $(sprint(showerror, err))"
        end
    end
    # Resolve snippet composition after every plugin has registered.
    try
        _resolve_snippet_includes!()
    catch err
        @error "snippet include resolution failed: $(sprint(showerror, err))"
    end
    return nothing
end

"""
    SampleEntry(name, plugin, bank_path, variants, metadata)

Identity of a single sample bank that's been loaded into Ressac.
Returned by [`sample_info`](@ref) and [`list_samples`](@ref).

- `name`        — Symbol used in patterns (`:kicky` → `s "kicky"`)
- `plugin`      — name of the plugin that contributed this bank
- `bank_path`   — absolute path to the file or directory backing the bank
- `variants`    — sorted absolute paths of the underlying audio files
                  (1 element for file-banks, ≥1 for directory-banks)
- `metadata`    — verbatim contents of `[samples.metadata.<name>]`,
                  empty Dict if none was provided
"""
struct SampleEntry
    name::Symbol
    plugin::String
    bank_path::String
    variants::Vector{String}
    metadata::Dict{String,Any}
end

"""
    _SAMPLE_REGISTRY

Module-level registry of every sample bank that's currently loaded,
keyed by short name. Populated by the `[samples]` handler at plugin load.
"""
const _SAMPLE_REGISTRY = Dict{Symbol,SampleEntry}()

"""
    register_sample!(entry::SampleEntry)

Register a sample bank. If `entry.name` is already registered, the new
entry is skipped and a `[WARN]` is logged (first-wins, same convention
as plugin shadowing).
"""
function register_sample!(entry::SampleEntry)
    if haskey(_SAMPLE_REGISTRY, entry.name)
        existing = _SAMPLE_REGISTRY[entry.name]
        @warn "sample bank '$(entry.name)' shadowed by plugin '$(entry.plugin)' (already loaded from '$(existing.plugin)')"
        return entry
    end
    _SAMPLE_REGISTRY[entry.name] = entry
    return entry
end

"""
    sample_info(name::Symbol) -> Union{SampleEntry, Nothing}
"""
sample_info(name::Symbol) = get(_SAMPLE_REGISTRY, name, nothing)

"""
    list_samples(pattern::Regex = r"") -> Vector{SampleEntry}

All registered sample banks whose `name` matches `pattern`, sorted by
`(plugin, name)`. Default pattern matches everything.
"""
function list_samples(pattern::Regex = r"")
    matches = SampleEntry[]
    for (name, entry) in _SAMPLE_REGISTRY
        occursin(pattern, String(name)) && push!(matches, entry)
    end
    sort!(matches, by = e -> (e.plugin, String(e.name)))
    return matches
end

"""
    InstrumentEntry(name, plugin, params, metadata)

A named bundle of `/dirt/play` params that the user can invoke by short
name. `params` is a `Vector{Pair{String,Any}}` (not Dict) so the order
declared in the TOML manifest survives the round-trip into OSC.

- `name`     — Symbol used in patterns (`:kicklourd`)
- `plugin`   — the plugin that contributed this preset
- `params`   — declared OSC params in TOML order (`s` first by convention)
- `metadata` — reserved keys pulled from the same manifest table
              (`tags`, `description`, `comment`)
"""
struct InstrumentEntry
    name::Symbol
    plugin::String
    params::Vector{Pair{String,Any}}
    metadata::Dict{String,Any}
end

"""
    SynthEntry(name, plugin, metadata)

Metadata-only registry entry for a synth exposed by a plugin. The
SynthDef itself is loaded via the existing `[synthdefs]` section; this
entry only enables `:synths` listing and `K` preview.
"""
struct SynthEntry
    name::Symbol
    plugin::String
    metadata::Dict{String,Any}
end

# True while a .jl synth file is being `Base.include`d at plugin
# load time. Read by `play_synth` (in SynthDSL) to know whether to
# ship `/dirt/evalSC` (just install the SynthDef on SC, no play)
# vs `/ressac/evalAndPlay` (install AND fire a one-shot Synth, the
# behaviour wanted for the `T`/`:test` interactive flow). Without
# this flag, plugin-loading the .jl files made SC play each synth
# once at session start — surprise "claquement" before the user
# touched any key.
const _INSTALLING_SYNTH = Ref{Bool}(false)

const _INSTRUMENT_REGISTRY = Dict{Symbol,InstrumentEntry}()
const _SYNTH_REGISTRY      = Dict{Symbol,SynthEntry}()
# Alias → SC SynthDef name. A SynthDef is named after its source
# file (e.g. plugins/user-synths/wob1.jl → SynthDef \wob1), and the
# user can give it a short alias via `@synth :wob …`. Pattern lookup
# `p"wob"` resolves via this table before shipping `s = wob1` to SC.
# Built and mutated by `register_synth_alias!` — collision-checked.
const _SYNTH_ALIASES       = Dict{Symbol,Symbol}()

"""
    register_instrument!(entry::InstrumentEntry)

First-wins registration. Shadow attempts log `[WARN] instrument 'X' …`
and are skipped.
"""
function register_instrument!(entry::InstrumentEntry)
    if haskey(_INSTRUMENT_REGISTRY, entry.name)
        existing = _INSTRUMENT_REGISTRY[entry.name]
        @warn "instrument '$(entry.name)' shadowed by plugin '$(entry.plugin)' (already loaded from '$(existing.plugin)')"
        return entry
    end
    _INSTRUMENT_REGISTRY[entry.name] = entry
    return entry
end

"""
    register_synth!(entry::SynthEntry)

First-wins registration. Same shadow semantics as
[`register_instrument!`](@ref).
"""
function register_synth!(entry::SynthEntry)
    if haskey(_SYNTH_REGISTRY, entry.name)
        existing = _SYNTH_REGISTRY[entry.name]
        @warn "synth '$(entry.name)' shadowed by plugin '$(entry.plugin)' (already loaded from '$(existing.plugin)')"
        return entry
    end
    _SYNTH_REGISTRY[entry.name] = entry
    return entry
end

instrument_info(name::Symbol) = get(_INSTRUMENT_REGISTRY, name, nothing)
synth_info(name::Symbol)      = get(_SYNTH_REGISTRY,      name, nothing)

"""
    register_synth_alias!(alias::Symbol, sc_name::Symbol) -> Bool

Bind `alias` to a SynthDef named `sc_name`. Refuses if `alias`
already points elsewhere — returns `false` and leaves the existing
mapping intact (call `unregister_synth_alias!` first). A no-op when
the alias already points to the same `sc_name`, or when alias and
sc_name are identical (no aliasing needed).
"""
function register_synth_alias!(alias::Symbol, sc_name::Symbol)
    alias === sc_name && return true   # no aliasing needed — identity
    existing = get(_SYNTH_ALIASES, alias, nothing)
    if existing === nothing
        _SYNTH_ALIASES[alias] = sc_name
        return true
    elseif existing === sc_name
        return true                     # idempotent re-registration
    else
        @error "alias '$alias' already points to '$existing'; refusing to rebind to '$sc_name'. Run `:alias-rm $alias` first."
        return false
    end
end

"""
    unregister_synth_alias!(alias::Symbol) -> Bool

Drop `alias` from the registry. Returns whether the alias existed.
"""
function unregister_synth_alias!(alias::Symbol)
    haskey(_SYNTH_ALIASES, alias) || return false
    delete!(_SYNTH_ALIASES, alias)
    return true
end

"""
    resolve_synth_name(name::Symbol) -> Symbol

Resolve a user-typed name to the SC SynthDef name to ship. If
`name` is an alias, returns the underlying `sc_name`. Otherwise
returns `name` unchanged — so calls flow through unmodified for
names that aren't aliased.
"""
resolve_synth_name(name::Symbol) = get(_SYNTH_ALIASES, name, name)

"""
    synth_alias_for(sc_name::Symbol) -> Union{Symbol, Nothing}

Reverse lookup: the (first) alias bound to `sc_name`, or `nothing`
if no alias points to it. Used for display in `:lib`.
"""
function synth_alias_for(sc_name::Symbol)
    for (alias, target) in _SYNTH_ALIASES
        target === sc_name && return alias
    end
    return nothing
end

"""
    list_instruments(pattern::Regex = r"") -> Vector{InstrumentEntry}
"""
function list_instruments(pattern::Regex = r"")
    out = InstrumentEntry[]
    for (name, entry) in _INSTRUMENT_REGISTRY
        occursin(pattern, String(name)) && push!(out, entry)
    end
    sort!(out, by = e -> (e.plugin, String(e.name)))
    return out
end

"""
    list_synths(pattern::Regex = r"") -> Vector{SynthEntry}
"""
function list_synths(pattern::Regex = r"")
    out = SynthEntry[]
    for (name, entry) in _SYNTH_REGISTRY
        occursin(pattern, String(name)) && push!(out, entry)
    end
    sort!(out, by = e -> (e.plugin, String(e.name)))
    return out
end
