# One-shot generator: reads the inline _PARAM_DOCS / _PARAM_EXAMPLES /
# _STARTER_PACKS dicts AND the legacy _SNIPPETS Vector from content_snippets.jl
# and writes them out as plugins/{core,reservoir,chaos}/docs/*.md and
# snippets/*.{toml,jl}.
#
# Routing:
#   doc name starts with "Reservoir." | "drive_" | "ADEX_"  → reservoir
#   doc name starts with "Chaos." OR is a chaos UGen        → chaos
#   everything else                                          → core
#
#   starter name starts with "reservoir-"                    → reservoir
#   starter name starts with "chaos-"                        → chaos
#   everything else                                          → core
#
#   every legacy _Snippet (browseable via :snip)            → core
#
# Run from the project root:
#   julia --project=. scripts/migrate_inline_to_plugins.jl
#
# This script is throwaway — delete it once the migration is reviewed
# and merged.

using Ressac
using TOML

const CHAOS_UGENS = Set([
    "lorenz", "henon", "logistic", "standard_map", "latoo",
    "lincong", "quad", "fbsine", "gbman", "cusp",
])

function route_doc(name::AbstractString)
    if startswith(name, "Reservoir.") || startswith(name, "drive_") || startswith(name, "ADEX_")
        return "reservoir"
    elseif startswith(name, "Chaos.") || name in CHAOS_UGENS
        return "chaos"
    else
        return "core"
    end
end

function route_starter(name::AbstractString)
    if startswith(name, "reservoir-")
        return "reservoir"
    elseif startswith(name, "chaos-")
        return "chaos"
    else
        return "core"
    end
end

# Best-effort tag inference from a doc name + short. Used only as hints;
# the PR author can hand-edit afterwards.
function infer_doc_tags(name::AbstractString, short::AbstractString)
    tags = String[]
    startswith(name, "Reservoir.") && push!(tags, "reservoir")
    startswith(name, "drive_") && push!(tags, "reservoir", "drive")
    startswith(name, "ADEX_") && push!(tags, "reservoir", "preset")
    startswith(name, "Chaos.") && push!(tags, "chaos")
    name in CHAOS_UGENS && push!(tags, "chaos", "ugen")
    occursin(r"\bRoute I\b", short) && push!(tags, "route")
    occursin(r"\bRoute II\b", short) && push!(tags, "route", "spectral")
    occursin(r"\bRoute III\b", short) && push!(tags, "route", "modulator")
    occursin(r"\bRoute IV\b", short) && push!(tags, "route", "pool")
    occursin(r"\bRoute V\b", short) && push!(tags, "route", "rate")
    unique!(tags)
    return tags
end

# Map mini-notation / special-char names to filesystem-safe identifiers.
const FILENAME_REPLACEMENTS = Dict(
    "" => "EMPTY",
    "*" => "STAR", "!" => "BANG", "[]" => "BRACKETS",
    "<>" => "ANGLES", "()" => "PARENS", "~" => "TILDE",
    "@dN" => "AT_DN",
)

function safe_filename(name::AbstractString)
    haskey(FILENAME_REPLACEMENTS, name) && return FILENAME_REPLACEMENTS[name]
    return replace(name, '.' => '_', '/' => '_')
end

# Dedent: find the minimum leading-whitespace count across non-blank
# lines, strip that prefix from each line. Used to clean up legacy
# snippets that were embedded as raw triple-strings with indentation
# matching the Julia source.
function dedent(s::AbstractString)
    lines = split(s, '\n')
    min_indent = typemax(Int)
    for ln in lines
        isempty(strip(ln)) && continue
        m = match(r"^(\s*)", ln)
        m === nothing && continue
        min_indent = min(min_indent, length(m.captures[1]))
    end
    min_indent == typemax(Int) && return s
    min_indent == 0 && return s
    out = String[]
    for ln in lines
        push!(out, length(ln) >= min_indent ? ln[min_indent+1:end] : ln)
    end
    return join(out, '\n')
end

function write_doc(plugin::AbstractString, name::AbstractString,
                   short::AbstractString, examples::Vector{String})
    plugin_root = joinpath("plugins", plugin)
    docs_dir = joinpath(plugin_root, "docs")
    mkpath(docs_dir)
    tags = infer_doc_tags(name, short)
    fm = Dict{String,Any}()
    fm["name"] = name
    fm["short"] = short
    fm["tags"] = tags
    fm["examples"] = examples
    io = IOBuffer()
    println(io, "+++")
    TOML.print(io, fm; sorted = true)
    println(io, "+++")
    println(io)
    println(io, "# $name")
    println(io)
    println(io, "(Migrated from inline `_PARAM_DOCS`. Body intentionally empty for now.)")
    out_path = joinpath(docs_dir, safe_filename(name) * ".md")
    write(out_path, take!(io))
end

function write_starter(plugin::AbstractString, name::AbstractString,
                        lines::Vector{String})
    plugin_root = joinpath("plugins", plugin)
    snippets_dir = joinpath(plugin_root, "snippets")
    mkpath(snippets_dir)
    description = ""
    for ln in lines
        m = match(r"^\s*#\s*(.+)$", ln)
        if m !== nothing
            description = strip(m.captures[1])
            break
        end
    end
    requires = String[]
    if plugin == "reservoir"
        push!(requires, "reservoir")
    elseif plugin == "chaos"
        push!(requires, "chaos")
    end
    tags = String[]
    plugin != "core" && push!(tags, plugin)
    sidecar_name = safe_filename(name) * ".jl"
    fm = Dict{String,Any}()
    fm["name"] = name
    fm["mode"] = "starter"
    fm["context"] = "patterns"   # starters always replace the patterns buffer
    fm["description"] = description
    fm["tags"] = tags
    fm["requires_plugins"] = requires
    fm["content_file"] = sidecar_name
    fm["includes"] = String[]
    io_toml = IOBuffer()
    TOML.print(io_toml, fm; sorted = true)
    write(joinpath(snippets_dir, safe_filename(name) * ".toml"),
          take!(io_toml))
    write(joinpath(snippets_dir, sidecar_name), join(lines, "\n"))
end

# Migrate one legacy _Snippet (from content_snippets.jl). All go to core
# under mode = "block", with context + tags carried over.
#
# If the trigger name collides with a starter (e.g. "house" exists as
# both a :starter pack AND a :snip block), suffix the legacy entry with
# "-block" so both can coexist in the unified registry. Three known
# collisions today: house, breakbeat, trap.
function write_legacy_snippet(snip, starter_names::Set{String})
    plugin_root = joinpath("plugins", "core")
    snippets_dir = joinpath(plugin_root, "snippets")
    mkpath(snippets_dir)
    name = snip.trigger in starter_names ?
           snip.trigger * "-block" : snip.trigger
    sidecar_name = safe_filename(name) * ".jl"
    fm = Dict{String,Any}()
    fm["name"] = name
    fm["mode"] = "block"
    fm["context"] = String(snip.context)
    fm["description"] = snip.description
    fm["tags"] = String[snip.category]
    fm["requires_plugins"] = String[]
    fm["content_file"] = sidecar_name
    fm["includes"] = String[]
    io_toml = IOBuffer()
    TOML.print(io_toml, fm; sorted = true)
    write(joinpath(snippets_dir, safe_filename(name) * ".toml"),
          take!(io_toml))
    body = strip(dedent(snip.body), ['\n'])
    write(joinpath(snippets_dir, sidecar_name), body * "\n")
end

function ensure_plugin_toml(plugin::AbstractString)
    plugin_root = joinpath("plugins", plugin)
    mkpath(plugin_root)
    manifest_path = joinpath(plugin_root, "plugin.toml")
    if isfile(manifest_path)
        raw = TOML.parsefile(manifest_path)
        changed = false
        if !haskey(raw, "docs")
            raw["docs"] = Dict("dir" => "docs")
            changed = true
        end
        if !haskey(raw, "snippets")
            raw["snippets"] = Dict("dir" => "snippets")
            changed = true
        end
        if changed
            io = IOBuffer()
            TOML.print(io, raw; sorted = true)
            write(manifest_path, take!(io))
            println("  extended manifest: $manifest_path")
        end
    else
        raw = Dict{String,Any}(
            "name" => plugin,
            "version" => "0.1.0",
            "description" => plugin == "core" ?
                "Core docs + starter snippets shipped with Ressac" :
                "$plugin plugin",
            "docs" => Dict("dir" => "docs"),
            "snippets" => Dict("dir" => "snippets"),
        )
        io = IOBuffer()
        TOML.print(io, raw; sorted = true)
        write(manifest_path, take!(io))
        println("  created manifest: $manifest_path")
    end
end

function main()
    docs = Ressac._PARAM_DOCS
    examples = Ressac._PARAM_EXAMPLES
    starters = Ressac._STARTER_PACKS
    legacy = Ressac._SNIPPETS  # Vector{_Snippet}

    println("Migrating $(length(docs)) docs, $(length(starters)) starters, " *
            "$(length(legacy)) legacy snippets...")

    for plugin in ("core", "reservoir", "chaos")
        ensure_plugin_toml(plugin)
    end

    for (name, short) in docs
        ex = String[String(x) for x in get(examples, name, String[])]
        write_doc(route_doc(name), name, short, ex)
    end

    for (name, lines) in starters
        write_starter(route_starter(name), name, String.(lines))
    end

    starter_names = Set(String(k) for k in keys(starters))
    for snip in legacy
        write_legacy_snippet(snip, starter_names)
    end

    println("Done. Run `git status` to see the generated files.")
end

main()
