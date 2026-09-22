# src/pattern_library.jl
# Bibliothèque de patterns — ranger un bloc `@dN` sous un nom, le
# retrouver, le recharger sur n'importe quel slot.
#
# Un pattern sauvé est un fichier texte dans `plugins/user-patterns/` :
# un en-tête commenté (tags, date) puis le code tel qu'il sera réinséré.
# Format volontairement lisible et éditable à la main, versionnable par
# l'utilisateur s'il le souhaite.

"""
    PatternEntry(name, code, tags, path)

Un pattern rangé : son nom, le code du bloc (`@dN …`), ses étiquettes et
le fichier d'où il vient.
"""
struct PatternEntry
    name::String
    code::String
    tags::Vector{String}
    path::String
end

_pattern_dir() = joinpath(pwd(), "plugins", "user-patterns")

# Nom de fichier sûr : lettres, chiffres, tiret, souligné.
_pattern_slug(name::AbstractString) = replace(strip(String(name)), r"[^\w\-]" => "-")

_pattern_path(name::AbstractString) = joinpath(_pattern_dir(), _pattern_slug(name) * ".jl")

"""
    save_pattern!(name, code; tags = String[]) -> PatternEntry

Range `code` sous `name` (écrase un homonyme). Le slot du code est
conservé tel quel : `load_pattern` le réécrit à la demande.
"""
function save_pattern!(name::AbstractString, code::AbstractString;
                       tags::AbstractVector{<:AbstractString} = String[])
    nm = strip(String(name))
    isempty(nm) && throw(ArgumentError("nom de pattern vide"))
    dir = _pattern_dir()
    isdir(dir) || mkpath(dir)
    body = strip(String(code))
    isempty(body) && throw(ArgumentError("pattern vide"))
    path = _pattern_path(nm)
    header = "# ressac-pattern: $nm\n" *
             (isempty(tags) ? "" : "# tags: " * join(tags, ", ") * "\n") *
             "# " * Dates.format(Dates.now(), "yyyy-mm-dd HH:MM") * "\n"
    write(path, header * body * "\n")
    return PatternEntry(nm, body, collect(String, tags), path)
end

"""
    load_pattern(name) -> Union{Nothing,PatternEntry}

Relit un pattern rangé. `nothing` s'il n'existe pas.
"""
function load_pattern(name::AbstractString)
    path = _pattern_path(name)
    isfile(path) || return nothing
    return _parse_pattern_file(path)
end

function _parse_pattern_file(path::AbstractString)
    src = try
        read(path, String)
    catch
        return nothing
    end
    name = splitext(basename(path))[1]
    tags = String[]
    body = String[]
    for line in split(src, '\n'; keepempty = true)
        st = strip(line)
        if startswith(st, "# ressac-pattern:")
            name = strip(st[length("# ressac-pattern:") + 1:end])
        elseif startswith(st, "# tags:")
            tags = [strip(t) for t in split(st[length("# tags:") + 1:end], ',') if !isempty(strip(t))]
        elseif startswith(st, "#") && isempty(body)
            continue                      # en-tête (date…)
        else
            push!(body, String(line))
        end
    end
    code = strip(join(body, "\n"))
    return PatternEntry(String(name), code, tags, String(path))
end

"""
    list_patterns() -> Vector{PatternEntry}

Tous les patterns rangés, par ordre alphabétique.
"""
function list_patterns()
    dir = _pattern_dir()
    isdir(dir) || return PatternEntry[]
    out = PatternEntry[]
    for f in sort(readdir(dir))
        endswith(f, ".jl") || continue
        e = _parse_pattern_file(joinpath(dir, f))
        e === nothing || push!(out, e)
    end
    return out
end

"""
    delete_pattern!(name) -> Bool

Supprime un pattern rangé. `false` s'il n'existait pas.
"""
function delete_pattern!(name::AbstractString)
    path = _pattern_path(name)
    isfile(path) || return false
    rm(path)
    return true
end

"""
    retarget_pattern(code, slot) -> String

Réécrit le `@dN` de tête pour viser `slot` : un pattern rangé depuis le
slot 1 se recharge sur le 5 sans édition.
"""
function retarget_pattern(code::AbstractString, slot::Integer)
    slot >= 1 || throw(ArgumentError("slot >= 1"))
    occursin(r"^\s*@d\d+\b", code) || return String(code)
    return replace(String(code), r"^(\s*)@d\d+\b" => SubstitutionString("\\1@d$(slot)"); count = 1)
end

"""
    pattern_slot(code) -> Union{Nothing,Int}

Numéro du slot que vise ce code, s'il en vise un.
"""
function pattern_slot(code::AbstractString)
    mt = match(r"^\s*@d(\d+)\b", String(code))
    mt === nothing ? nothing : parse(Int, mt.captures[1])
end
