# src/usage.jl
# Ce que le joueur a réellement joué. Chaque nom documenté d'un bloc évalué
# avec succès (ou d'un son testé) est compté, d'un lancement à l'autre.
#
# Deux usages : la complétion propose d'abord ce qu'on emploie, et la fiche
# d'une fonction montre ses voisines — dont celle qu'on n'a « pas encore
# essayée ». Ressac sert à explorer : il vaut mieux désigner la porte d'à
# côté que de laisser deviner qu'elle existe.

const _PLAYED = Ref{Dict{String,Int}}(Dict{String,Int}())
const _PLAYED_LOADED = Ref(false)
# Change à chaque comptage : les fiches déjà rendues savent qu'elles datent.
const _PLAYED_EPOCH = Ref(0)

_played_path() = joinpath(_config_dir(), "played.toml")

function _played_load!()
    _PLAYED_LOADED[] && return
    _PLAYED_LOADED[] = true
    isfile(_played_path()) || return
    try
        data = TOML.parsefile(_played_path())
        for (k, v) in get(data, "counts", Dict{String,Any}())
            v isa Integer && (_PLAYED[][String(k)] = Int(v))
        end
    catch
    end
    return
end

function _played_save!()
    try
        mkpath(dirname(_played_path()))
        open(_played_path(), "w") do io
            println(io, "# Ce que tu as joué dans Ressac : le nombre d'évaluations réussies par nom.")
            TOML.print(io, Dict{String,Any}("counts" => _PLAYED[]); sorted = true)
        end
    catch
    end
    return
end

_played_count(name::AbstractString) = (_played_load!(); get(_PLAYED[], String(name), 0))

# Une fiche de fonction (pas un terme du glossaire) porte-t-elle ce nom ?
function _is_documented_function(name::AbstractString)
    e = lookup_doc(String(name))
    return e !== nothing && !(:glossary in e.tags)
end

"""
    _played_names(src) -> Vector{String}

Les noms documentés employés dans `src`, sans doublon : les identifiants du
code, pas ceux des chaînes ni des commentaires.
"""
function _played_names(src::AbstractString)
    out = String[]
    for line in split(String(src), '\n')
        code = replace(SynthDSL._split_code_comment(line)[1], r"\"(?:[^\"\\]|\\.)*\"" => "\"\"")
        for mt in eachmatch(r"(?<![\w.:@])[A-Za-z_][A-Za-z0-9_]*!?", code)
            w = String(mt.match)
            (w in out || !_is_documented_function(w)) && continue
            push!(out, w)
        end
    end
    return out
end

"""
    _note_played!(src)

Compte une évaluation réussie pour chaque nom documenté de `src`.
"""
function _note_played!(src::AbstractString)
    names = _played_names(src)
    isempty(names) && return
    _played_load!()
    for w in names
        _PLAYED[][w] = get(_PLAYED[], w, 0) + 1
    end
    _PLAYED_EPOCH[] += 1
    _played_save!()
    return
end

"""
    _doc_neighbours(entry) -> Vector{String}

Les fonctions voisines d'une fiche : celles que sa ligne « See also » nomme
et qui ont elles-mêmes une fiche. (Les termes de glossaire de la même ligne
ne sont pas des fonctions à essayer.)
"""
function _doc_neighbours(entry::DocEntry)
    mt = match(r"(?m)^See also\s*:\s*(.+)$", entry.body)
    mt === nothing && return String[]
    out = String[]
    for raw in split(mt.captures[1], ',')
        w = strip(raw, [' ', '`', '.'])
        (isempty(w) || w == entry.name || w in out) && continue
        _is_documented_function(w) && push!(out, String(w))
    end
    return out
end

# La première voisine jamais jouée, ou `nothing`.
_untried(names::AbstractVector{<:AbstractString}) =
    (i = findfirst(n -> _played_count(n) == 0, names); i === nothing ? nothing : String(names[i]))
