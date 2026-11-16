# src/editor_edit.jl
# Écrire dans un buffer. Tout ce que Ressac change dans un éditeur passe par
# ici, pour deux raisons que chaque fonction d'édition oubliait à son tour :
#
#   • l'annulation. `Tachikoma.set_text!` remplace le texte sans rien
#     mémoriser : une édition faite par Ressac (dw, un nudge, un snippet, une
#     complétion, `:prune`…) ne s'annulait pas, ou emportait avec elle
#     l'édition précédente. `_edit_text!` pose un instantané avant.
#   • les caractères. Le curseur de l'éditeur compte en caractères
#     (`ed.lines` est un `Vector{Vector{Char}}`) ; découper une `String` à
#     une colonne de curseur, c'est l'indexer en octets, et le premier
#     accent à gauche décale tout ou lève `StringIndexError`. Les éditions
#     travaillent sur `_buffer_lines(ed)` — des vecteurs de `Char` — ou
#     convertissent une position de regex avec `_char_col`.
#
# `_load_text!` est l'autre geste : remplir un buffer neuf (un onglet qu'on
# ouvre). Pas d'instantané, l'historique repart de là.
#
# Aucun autre fichier n'appelle `TK.set_text!` sur un `CodeEditor` (règle
# vérifiée par test_editor_edit.jl).

"""
    _edit_text!(ed, text; row = nothing, col = nothing)

Remplace le texte d'un buffer **vivant**. Annulable d'un seul `u`, sans
toucher au défilement ; le curseur va en `(row, col)` s'ils sont donnés,
sinon il reste où il était (ramené dans le texte). Sans effet — et sans
instantané — si le texte ne change pas.
"""
function _edit_text!(ed::TK.CodeEditor, text::AbstractString;
                     row::Union{Nothing,Int} = nothing, col::Union{Nothing,Int} = nothing)
    text = String(text)
    old_row, old_col = ed.cursor_row, ed.cursor_col
    if text != TK.text(ed)
        scroll, hscroll = ed.scroll_offset, ed.h_scroll
        TK._push_undo!(ed; force = true)
        ed.last_edit_was_char = false
        TK.set_text!(ed, text)
        ed.scroll_offset = clamp(scroll, 0, max(0, length(ed.lines) - 1))
        ed.h_scroll = hscroll
    end
    ed.cursor_row = clamp(something(row, old_row), 1, length(ed.lines))
    ed.cursor_col = clamp(something(col, old_col), 0, length(ed.lines[ed.cursor_row]))
    return ed
end

"""
    _edit_lines!(ed, lines; row = nothing, col = nothing)

`_edit_text!` à partir de lignes de caractères — la forme dans laquelle une
édition calcule (voir [`_buffer_lines`](@ref)).
"""
function _edit_lines!(ed::TK.CodeEditor, lines::Vector{Vector{Char}}; kwargs...)
    isempty(lines) && (lines = [Char[]])
    return _edit_text!(ed, join((String(l) for l in lines), '\n'); kwargs...)
end

"""
    _load_text!(ed, text)

Remplit un buffer **neuf** (un onglet qu'on ouvre, un fichier qu'on charge
dans une pane vide) : pas d'instantané d'annulation, l'historique est vidé,
le curseur va au début.
"""
function _load_text!(ed::TK.CodeEditor, text::AbstractString)
    TK.set_text!(ed, String(text))
    empty!(ed.undo_stack); empty!(ed.redo_stack)
    ed.last_edit_was_char = false
    ed.cursor_row = 1; ed.cursor_col = 0
    return ed
end

"""
    _edit_line!(ed, row, new_line; col = nothing)

Remplace une seule ligne du buffer (voir [`_edit_text!`](@ref)).
"""
function _edit_line!(ed::TK.CodeEditor, row::Int, new_line::AbstractString; col::Union{Nothing,Int} = nothing)
    1 <= row <= length(ed.lines) || return ed
    lines = _buffer_lines(ed)
    lines[row] = collect(new_line)
    return _edit_lines!(ed, lines; row = col === nothing ? nothing : row, col = col)
end

"Une copie de travail des lignes du buffer, en caractères."
_buffer_lines(ed::TK.CodeEditor) = Vector{Char}[copy(l) for l in ed.lines]

"""
    _char_col(line, byte_offset) -> Int

La colonne (0-based, en caractères — celle du curseur) du caractère qui
commence à l'octet `byte_offset` de `line`. Pour convertir `mt.offset` d'un
`RegexMatch`, qui compte en octets.
"""
_char_col(line::AbstractString, byte_offset::Integer) = length(line, 1, byte_offset) - 1

"""
    _char_span(line, mt::RegexMatch, capture = 0) -> (first, last)

Les colonnes de caractères (0-based, `last` exclu) que couvre une
correspondance de regex — ou l'une de ses captures.
"""
function _char_span(line::AbstractString, mt::RegexMatch, capture::Int = 0)
    off  = capture == 0 ? mt.offset : mt.offsets[capture]
    text = capture == 0 ? mt.match  : mt.captures[capture]
    first = _char_col(line, off)
    return (first, first + length(text))
end

# Les `n` premiers caractères d'une chaîne, et le reste.
_take_chars(s::AbstractString, n::Int) = String(collect(s)[1:clamp(n, 0, length(s))])
_drop_chars(s::AbstractString, n::Int) = String(collect(s)[(clamp(n, 0, length(s)) + 1):end])
