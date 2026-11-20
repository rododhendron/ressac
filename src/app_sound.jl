# src/app_sound.jl
# Un son vit dans le texte principal : un bloc `@synth :nom …` parmi les
# patterns. Il n'y a pas d'autre endroit où il s'écrit — ni volet, ni onglet.
# C'est là qu'il arrive (`gs`, `:synth nom`, la librairie, l'explorateur),
# là qu'on le travaille (le mode suit le curseur : dans un bloc `@synth`,
# les touches sont celles du son), et de là qu'on le range (`:save`).
#
# L'étendue du bloc est celle de `_logical_block_range` — la même que pour
# `e` : ce que `:save` range est exactement ce que `e` évalue.

const _SOUND_HEAD_RX = r"^\s*@synth\s+:(\w+)"

"Un bloc `@synth` du texte : son nom, sa première et sa dernière ligne."
struct SoundBlock
    name::String
    row::Int
    last_row::Int
end

"""
    _sound_block_at(lines, row) -> SoundBlock | nothing

Le bloc `@synth` qui contient la ligne `row`.
"""
function _sound_block_at(lines::AbstractVector, row::Int)
    1 <= row <= length(lines) || return nothing
    (a, b) = _logical_block_range(lines, row)
    mt = match(_SOUND_HEAD_RX, String(lines[a]))
    mt === nothing && return nothing
    return SoundBlock(String(mt.captures[1]), a, b)
end

# Le bloc qui définit le son `name`, où qu'il soit dans le texte.
function _sound_block_named(lines::AbstractVector, name::AbstractString)
    for (i, l) in enumerate(lines)
        mt = match(_SOUND_HEAD_RX, String(l))
        (mt !== nothing && mt.captures[1] == name) && return _sound_block_at(lines, i)
    end
    return nothing
end

# Le texte du bloc `@synth` qui contient `row`, dans des lignes qui ne sont
# pas (encore) celles de l'éditeur — l'essai d'un maillon, par exemple.
function _sound_text_in(lines::AbstractVector, row::Int)
    b = _sound_block_at(lines, row)
    b === nothing && return ""
    return join((String(l) for l in lines[b.row:b.last_row]), '\n')
end

"""
    _current_sound(m) -> Sound | nothing

Le son sur lequel on travaille : le bloc `@synth` où est le curseur du
texte principal — que le clavier y soit, ou dans une pane à côté (la DOC,
la MODULATION).
"""
function _current_sound(m::RessacApp)
    ed = _patterns_editor(m)
    ed === nothing && return nothing
    b = _sound_block_at(ed.lines, ed.cursor_row)
    return b === nothing ? nothing : Sound(b.name, ed)
end

# Le même, seulement quand le clavier est dans le texte.
function _sound_under_cursor(m::RessacApp)
    _focused_buffer(m) === nothing && return nothing
    return _current_sound(m)
end

"""
    _sound_rows(s) -> (first, last) | nothing

Les lignes du son dans son éditeur, maintenant : le bloc du curseur s'il
porte ce nom, sinon le premier bloc de ce nom. `nothing` s'il a disparu.
"""
function _sound_rows(s::Sound)
    lines = s.code_editor.lines
    here = _sound_block_at(lines, s.code_editor.cursor_row)
    (here !== nothing && here.name == s.name) && return (here.row, here.last_row)
    b = _sound_block_named(lines, s.name)
    return b === nothing ? nothing : (b.row, b.last_row)
end

function _sound_text(s::Sound)
    r = _sound_rows(s)
    r === nothing && return ""
    return join((String(l) for l in s.code_editor.lines[r[1]:r[2]]), '\n')
end

"""
    _sound_write!(s, text; row = nothing, col = nothing) -> Bool

Remplace le texte du son (un seul `u` l'annule). `row` est une ligne du
son, comptée depuis sa première ; sans elle, le curseur reste où il est
(ramené dans le bloc s'il en sortait).
"""
function _sound_write!(s::Sound, text::AbstractString; row::Union{Nothing,Int} = nothing,
                       col::Union{Nothing,Int} = nothing)
    r = _sound_rows(s)
    r === nothing && return false
    ed = s.code_editor
    block = split(String(rstrip(text, '\n')), '\n')
    lines = [String(l) for l in ed.lines]
    splice!(lines, r[1]:r[2], block)
    last = r[1] + length(block) - 1
    at = row === nothing ? clamp(ed.cursor_row, r[1], last) : clamp(r[1] + row - 1, r[1], last)
    _edit_text!(ed, join(lines, '\n'); row = at, col = col)
    return true
end

# Ce qu'on écrit dans le texte : le son, sans la ligne du génome embarqué
# (un millier de caractères que personne ne lit ; le texte suffit à le relire).
function _sound_text_for_editor(text::AbstractString)
    keep = [l for l in split(String(text), '\n') if !startswith(l, _GENOME_COMMENT_PREFIX)]
    return String(strip(join(keep, '\n'), '\n'))
end

# Définit le son pour SuperCollider sans le jouer.
function _install_sound_text!(m::RessacApp, text::AbstractString)
    was = _INSTALLING_SYNTH[]
    _INSTALLING_SYNTH[] = true
    try
        Core.eval(SynthDSL, SynthDSL._dsl_parse_all(String(text)))
        return true
    catch err
        _push_app_log!(m, "[ERROR] ce son ne se définit pas : $(first(sprint(showerror, err), 160))")
        return false
    finally
        _INSTALLING_SYNTH[] = was
    end
end

"""
    _insert_sound_block!(m, name, text) -> Bool

Écrit le son `name` dans le texte principal et y amène le clavier. Un bloc
du même nom est remplacé sur place ; sinon le son se pose sous le bloc du
curseur. Il est défini aussitôt : `s("nom")` le joue, `e` sur son bloc le
fait entendre. `u` l'enlève.
"""
function _insert_sound_block!(m::RessacApp, name::AbstractString, text::AbstractString)
    ed = _patterns_editor!(m)
    ed === nothing && return false
    _focus_patterns!(m)
    block = split(_align_dsl_synth_name(_sound_text_for_editor(text), name), '\n')
    head = something(findfirst(l -> occursin(_SOUND_HEAD_RX, l), block), 1)
    lines = [String(l) for l in ed.lines]
    old = _sound_block_named(lines, name)
    if old !== nothing
        # Le bloc seul est remplacé : les commentaires du fichier n'y entrent pas.
        splice!(lines, old.row:old.last_row, block[head:end])
        row = old.row
    else
        at = clamp(ed.cursor_row, 1, length(lines))
        after = isempty(strip(lines[at])) ? at - 1 : _logical_block_range(lines, at)[2]
        lead = after >= 1 && !isempty(strip(lines[after]))
        piece = String[]
        lead && push!(piece, "")
        append!(piece, block)
        (after < length(lines) && !isempty(strip(lines[after + 1]))) && push!(piece, "")
        splice!(lines, (after + 1):after, piece)
        row = after + (lead ? 1 : 0) + head
    end
    _edit_text!(ed, join(lines, '\n'); row = row, col = 0)
    ed.mode = :normal
    text = join(block, '\n')
    # Connu tout de suite, que SuperCollider réponde ou non : `s("nom")` ne
    # passe pas pour un son inconnu.
    _install_sound_text!(m, text) &&
        register_synth!(SynthEntry(Symbol(name), "user-dsl",
            Dict{String,Any}("description" => "DSL-defined", "tags" => ["dsl"],
                             "params" => _dsl_params_from_text(text))); update = true)
    return true
end

"""
    _save_sound!(m, s; new_name = nothing) -> Bool

`:save` (ou `Espace W`) sur un son : il est rangé dans
`plugins/user-synths/<nom>.jl`. Avec `new_name`, sous ce nom-là, et le bloc
du texte prend ce nom.
"""
function _save_sound!(m::RessacApp, s::Sound; new_name::Union{Nothing,AbstractString} = nothing)
    name = new_name === nothing ? s.name : String(new_name)
    if !occursin(r"^[A-Za-z_]\w*$", name)
        _push_app_log!(m, "[ERROR] :save — « $name » n'est pas un nom de son (lettres, chiffres, _)")
        return false
    end
    text = _align_dsl_synth_name(_sound_text(s), name)
    isempty(text) && return false
    name == s.name || _sound_write!(s, text)
    path = _app_synth_path(name; mode = :dsl)
    existed = isfile(path)
    mkpath(dirname(path))
    write(path, text * "\n")
    register_synth!(SynthEntry(Symbol(name), "user-synths",
        Dict{String,Any}("description" => "live-edited synth",
                         "tags" => ["user", "dsl"],
                         "params" => _dsl_params_from_text(text))); update = true)
    _push_app_log!(m, "[INFO] son « $name » $(existed ? "réécrit" : "rangé") → $path")
    return true
end
