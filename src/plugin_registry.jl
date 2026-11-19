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
    section_names = _ordered_sections(keys(m.sections))
    for sec_str in section_names
        sec = Symbol(sec_str)
        h = get_section_handler(sec)
        if h === nothing
            @warn "no handler registered for section ':$sec_str' (in plugin '$(m.name)'); skipping"
            continue
        end
        try
            # invokelatest dispatches at the current world-age. Without
            # it, a section handler that was registered by an earlier
            # section's [julia] include (within the SAME plugin load)
            # is "too new" to be called from this loop's world.
            Base.invokelatest(h, m.dir, m.sections[sec_str], m.name)
        catch err
            @error "handler ':$sec_str' for plugin '$(m.name)' raised: $(sprint(showerror, err))"
        end
    end
    return nothing
end

# L'ordre des sections d'un plugin. Il compte : `[julia]` peut enregistrer
# des handlers ou définir ce que les autres utilisent ; `[synths]` (les
# métadonnées) passe avant `[synthdefs]` (le son). Une section absente de la
# liste — celle d'un handler de plugin — vient après, par ordre alphabétique.
# (L'ordre était celui du hachage du Dict : le même à chaque fois par
# chance, pas par contrat.)
const _SECTION_ORDER = ["julia", "samples", "scales", "instruments", "synths", "synthdefs", "snippets", "docs", "wiki"]

function _ordered_sections(names)
    rank(n) = something(findfirst(==(n), _SECTION_ORDER), length(_SECTION_ORDER) + 1)
    return sort!(String[String(n) for n in names]; by = n -> (rank(n), n))
end

"""
    default_plugin_path() -> Vector{String}

Plugin search path used by default at session start. Order:
1. `\$PWD/plugins`                        — project tree
2. `~/.config/ressac/plugins`             — user overrides
3. `~/.cache/ressac/plugins`              — auto-generated (e.g. sc-autodiscover)
4. Entries from `\$RESSAC_PLUGIN_PATH` (`:`-separated).

Two different questions, two answers:

- the same **plugin** found in several directories is loaded from the first
  one that has it (`discover_plugins`): the project tree beats the user's
  config, which beats the auto-generated cache;
- the same **name** (a doc, a snippet, a sound…) declared by two different
  plugins goes to the one loaded last, with a warning (`_register!`).
  `core` is loaded first precisely so that anything can override it.

Non-existent entries are kept in the list and silently skipped by
`discover_plugins`.
"""
function default_plugin_path()
    path = String[joinpath(_project_dir(), "plugins")]
    push!(path, joinpath(_config_dir(), "plugins"))
    push!(path, joinpath(_cache_dir(), "plugins"))
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

# ── Verrou et règle d'enregistrement des registres ───────────────────
#
# Samples, instruments, synths et alias sont écrits par la tâche UI
# (chargement des plugins, T, :w, :alias…) et lus par le thread du scheduler
# à chaque événement (`event_to_osc` → `instrument_info`, `synth_info`,
# `resolve_synth_name`). Un `Dict` qui se réorganise pendant une lecture peut
# lever ou rendre n'importe quoi : toute écriture et toute lecture par les
# fonctions ci-dessous se fait sous `_REGISTRY_LOCK`.
#
# Une seule règle pour tous les registres — samples, instruments, synths,
# et aussi fiches, snippets, gammes (`_register!`) :
#   • nom libre                         → l'entrée est posée ;
#   • même plugin qui se ré-enregistre  → l'entrée est remplacée (rechargement) ;
#   • un AUTRE plugin                   → le dernier chargé l'emporte, et on
#     le dit (`shadowed by plugin …`). C'est ce qui permet à un plugin du
#     joueur de remplacer une fiche, un snippet ou un son de `core` (chargé
#     en premier, voir `_load_plugins`) — et c'est ce que SuperCollider fait
#     de toute façon d'un SynthDef redéfini : le dernier `.add` joue.
#   • `update = true` (un geste du joueur : T sur un @synth, :w, sculpt,
#     import) → l'entrée est mise à jour en gardant son propriétaire ;
#   • l'entrée vient d'un geste du joueur (`_LIVE_OWNER`) et un plugin la
#     déclare ensuite → le plugin en devient propriétaire, les deux sont
#     fusionnées (l'ordre de chargement ne change pas le résultat).
const _REGISTRY_LOCK = ReentrantLock()
# Propriétaire des entrées nées d'une évaluation en direct (`@synth` + T).
const _LIVE_OWNER = "user-dsl"

function _register!(merge_entries, registry::AbstractDict, entry, what::String; update::Bool)
    shadowed_by = lock(_REGISTRY_LOCK) do
        existing = get(registry, entry.name, nothing)
        if existing === nothing || existing.plugin == entry.plugin
            registry[entry.name] = entry
            nothing
        elseif update
            registry[entry.name] = merge_entries(existing, entry, existing.plugin)
            nothing
        elseif existing.plugin == _LIVE_OWNER
            registry[entry.name] = merge_entries(existing, entry, entry.plugin)
            nothing
        else
            registry[entry.name] = entry          # le dernier chargé l'emporte
            existing.plugin
        end
    end
    shadowed_by === nothing ||
        @warn "$what '$(entry.name)' shadowed by plugin '$(entry.plugin)' (previously from '$(shadowed_by)')"
    return entry
end

_registry_get(registry::Dict{Symbol,E}, name::Symbol) where {E} =
    lock(() -> get(registry, name, nothing), _REGISTRY_LOCK)

"""
    _reset_registries!()

Vide samples, instruments, synths et alias — avant de recharger les plugins
(`restart_live!`), pour repartir de ce que disent les manifestes aujourd'hui.
"""
function _reset_registries!()
    lock(_REGISTRY_LOCK) do
        empty!(_SAMPLE_REGISTRY); empty!(_INSTRUMENT_REGISTRY)
        empty!(_SYNTH_REGISTRY);  empty!(_SYNTH_ALIASES)
    end
    return nothing
end

"""
    register_sample!(entry::SampleEntry; update = false)

Register a sample bank. See the registration rule above `_register!`:
the same plugin (reload) or `update = true` (the player's own `:import`)
replaces the entry silently; a different plugin claiming a taken name
replaces it too — the last loaded wins — with a `[WARN]` naming both.
"""
register_sample!(entry::SampleEntry; update::Bool = false) =
    _register!((old, new, owner) -> new, _SAMPLE_REGISTRY, entry, "sample bank"; update)

"""
    sample_info(name::Symbol) -> Union{SampleEntry, Nothing}
"""
sample_info(name::Symbol) = _registry_get(_SAMPLE_REGISTRY, name)

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
# Paires clé/valeur ajoutées au /ressac/evalAndPlay du prochain T (note d'audition).
const _AUDITION_ARGS = Ref{Vector{Any}}(Any[])
# Capture des drones : quand c'est un Vector, `play_synth` n'envoie rien et
# y pousse `(nom, source SC de la variante à porte, paramètres effectifs)`.
# L'éditeur (D) évalue le buffer ainsi, puis lance le drone lui-même.
const _DRONE_CAPTURE = Ref{Any}(nothing)

const _INSTRUMENT_REGISTRY = Dict{Symbol,InstrumentEntry}()
const _SYNTH_REGISTRY      = Dict{Symbol,SynthEntry}()
# Alias → SC SynthDef name. A SynthDef is named after its source
# file (e.g. plugins/user-synths/wob1.jl → SynthDef \wob1), and the
# user can give it a short alias via `@synth :wob …`. Pattern lookup
# `p"wob"` resolves via this table before shipping `s = wob1` to SC.
# Built and mutated by `register_synth_alias!` — collision-checked.
const _SYNTH_ALIASES       = Dict{Symbol,Symbol}()

"""
    register_instrument!(entry::InstrumentEntry; update = false)

Same registration rule as [`register_sample!`](@ref).
"""
register_instrument!(entry::InstrumentEntry; update::Bool = false) =
    _register!((old, new, owner) -> new, _INSTRUMENT_REGISTRY, entry, "instrument"; update)

"""
    register_synth!(entry::SynthEntry; update = false)

Same registration rule as [`register_sample!`](@ref). With `update = true`
the entry is **merged** into the existing one: the first owner and its
metadata (description, tags from the manifest) stay, the newcomer fills in
what was missing and brings its `params`. That is how a `@synth` evaluated with T, or saved with `:w`, brings its
current `params` to a synth the manifest already declared — the scheduler
reads them to route pitch (`_pitch_target`).
"""
register_synth!(entry::SynthEntry; update::Bool = false) =
    _register!(_merge_synth_entries, _SYNTH_REGISTRY, entry, "synth"; update)

function _merge_synth_entries(old::SynthEntry, new::SynthEntry, owner::String)
    # Le propriétaire garde sa description et ses tags ; l'autre ne fait que
    # compléter. Les `params`, eux, suivent toujours la définition la plus
    # récente qui en donne.
    meta = owner == old.plugin ? merge(new.metadata, old.metadata) : merge(old.metadata, new.metadata)
    haskey(new.metadata, "params") && (meta["params"] = new.metadata["params"])
    return SynthEntry(old.name, owner, meta)
end

instrument_info(name::Symbol) = _registry_get(_INSTRUMENT_REGISTRY, name)
synth_info(name::Symbol)      = _registry_get(_SYNTH_REGISTRY,      name)

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
    existing = lock(_REGISTRY_LOCK) do
        cur = get(_SYNTH_ALIASES, alias, nothing)
        cur === nothing && (_SYNTH_ALIASES[alias] = sc_name)
        cur
    end
    (existing === nothing || existing === sc_name) && return true
    @error "alias '$alias' already points to '$existing'; refusing to rebind to '$sc_name'. Run `:alias-rm $alias` first."
    return false
end

"""
    unregister_synth_alias!(alias::Symbol) -> Bool

Drop `alias` from the registry. Returns whether the alias existed.
"""
function unregister_synth_alias!(alias::Symbol)
    lock(_REGISTRY_LOCK) do
        haskey(_SYNTH_ALIASES, alias) || return false
        delete!(_SYNTH_ALIASES, alias)
        return true
    end
end

"""
    resolve_synth_name(name::Symbol) -> Symbol

Resolve a user-typed name to the SC SynthDef name to ship. If
`name` is an alias, returns the underlying `sc_name`. Otherwise
returns `name` unchanged — so calls flow through unmodified for
names that aren't aliased.
"""
resolve_synth_name(name::Symbol) = lock(() -> get(_SYNTH_ALIASES, name, name), _REGISTRY_LOCK)

"""
    synth_alias_for(sc_name::Symbol) -> Union{Symbol, Nothing}

Reverse lookup: the (first) alias bound to `sc_name`, or `nothing`
if no alias points to it. Used for display in `:lib`.
"""
function synth_alias_for(sc_name::Symbol)
    lock(_REGISTRY_LOCK) do
        for (alias, target) in _SYNTH_ALIASES
            target === sc_name && return alias
        end
        return nothing
    end
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
