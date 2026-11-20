# src/app_sound.jl
# Un son écrit dans le texte principal : un bloc `@synth :nom …` parmi les
# patterns. C'est là qu'un son arrive (depuis l'explorateur), là qu'on le
# retouche et qu'on l'évalue (`e`), et de là qu'on le range (`:keep`).
#
# L'étendue du bloc est celle de `_logical_block_range` — la même que pour
# `e` : ce que `:keep` range est exactement ce que `e` évalue.

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

"""
    _sound_under_cursor(m) -> (editor, SoundBlock) | nothing

Le son sous le curseur, quand le clavier est dans le texte principal.
"""
function _sound_under_cursor(m::RessacApp)
    buf = _focused_buffer(m)
    (buf === nothing || buf.role !== :patterns) && return nothing
    ed = buf.code_editor
    sb = _sound_block_at(ed.lines, ed.cursor_row)
    return sb === nothing ? nothing : (ed, sb)
end

_sound_text(ed, sb::SoundBlock) = join((String(l) for l in ed.lines[sb.row:sb.last_row]), '\n')

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
    lines = [String(l) for l in ed.lines]
    old = _sound_block_named(lines, name)
    if old !== nothing
        splice!(lines, old.row:old.last_row, block)
        row = old.row
    else
        at = clamp(ed.cursor_row, 1, length(lines))
        after = isempty(strip(lines[at])) ? at - 1 : _logical_block_range(lines, at)[2]
        piece = String[]
        (after >= 1 && !isempty(strip(lines[after]))) && push!(piece, "")
        append!(piece, block)
        (after < length(lines) && !isempty(strip(lines[after + 1]))) && push!(piece, "")
        row = after + 1 + ((after >= 1 && !isempty(strip(lines[after]))) ? 1 : 0)
        splice!(lines, (after + 1):after, piece)
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
    _keep_sound_block!(m, ed, sb; new_name = nothing) -> Bool

`:keep` sur un bloc `@synth` : le son est rangé dans
`plugins/user-synths/<nom>.jl`. Avec `new_name`, sous ce nom-là, et le bloc
du texte prend ce nom.
"""
function _keep_sound_block!(m::RessacApp, ed, sb::SoundBlock; new_name::Union{Nothing,AbstractString} = nothing)
    name = new_name === nothing ? sb.name : String(new_name)
    if !occursin(r"^[A-Za-z_]\w*$", name)
        _push_app_log!(m, "[ERROR] :keep — « $name » n'est pas un nom de son (lettres, chiffres, _)")
        return false
    end
    text = _align_dsl_synth_name(_sound_text(ed, sb), name)
    if name != sb.name
        lines = [String(l) for l in ed.lines]
        splice!(lines, sb.row:sb.last_row, split(text, '\n'))
        _edit_text!(ed, join(lines, '\n'))
    end
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
