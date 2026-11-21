# src/row_layout.jl
# Des lignes entre les lignes. Sous le bloc d'un slot qui joue, le texte
# s'écarte pour laisser la place à ce qui l'accompagne : ses réglages
# (une réglette par nombre) et le visuel qu'il demande (`|> pianoroll()`…).
# Ces rangées ne font pas partie du texte : ni numéro, ni curseur.
#
# L'éditeur (Tachikoma) dessine le texte serré, comme toujours ; juste après,
# `_shift_rows!` descend chaque ligne de ce que les rangées du dessus lui
# prennent. Tout ce qui convertit « ligne du texte » ⟷ « ligne d'écran »
# passe par `_gap_before` / `_text_row_at`.

# L'éditeur mis en page à cette image, et pour chaque ligne du texte le
# nombre de rangées ouvertes SOUS elle.
const _ROW_GAPS = Ref{Tuple{Any,Dict{Int,Int}}}((nothing, Dict{Int,Int}()))

"Les rangées ouvertes au-dessus de la ligne `row`, depuis le haut de la vue."
function _gap_before(ed, row::Int)
    (e, g) = _ROW_GAPS[]
    (e === ed && !isempty(g)) || return 0
    s = 0
    for (r, n) in g
        ed.scroll_offset < r < row && (s += n)
    end
    return s
end

"""
    _text_row_at(ed, visual) -> Int | nothing

La ligne du texte dessinée à la rangée `visual` de la vue (0 = la première),
ou `nothing` si cette rangée est une rangée ouverte.
"""
function _text_row_at(ed, visual::Int)
    (e, g) = _ROW_GAPS[]
    (e === ed && !isempty(g)) || return ed.scroll_offset + visual + 1
    v = 0
    row = ed.scroll_offset + 1
    while v <= visual
        v == visual && return row
        v += 1 + get(g, row, 0)
        row += 1
    end
    return nothing
end

"""
    _shift_rows!(buf, rect, ed)

Écarte les lignes déjà dessinées dans `rect` (la zone du texte, numéros
compris) selon `_ROW_GAPS`. Les rangées ouvertes sont laissées vides.
"""
function _shift_rows!(buf::TK.Buffer, rect::TK.Rect, ed)
    (e, g) = _ROW_GAPS[]
    (e === ed && !isempty(g)) || return
    any(((r, _),) -> ed.scroll_offset < r <= ed.scroll_offset + rect.height, g) || return
    xs = rect.x:(rect.x + rect.width - 1)
    old = [[buf.content[TK.buf_index(buf, x, rect.y + v)] for x in xs] for v in 0:(rect.height - 1)]
    blank = TK.Cell(' ', TK.Style(), "")
    for v in 0:(rect.height - 1)
        row = _text_row_at(ed, v)
        src = row === nothing ? -1 : row - 1 - ed.scroll_offset
        for (k, x) in enumerate(xs)
            buf.content[TK.buf_index(buf, x, rect.y + v)] = 0 <= src < rect.height ? old[src + 1][k] : blank
        end
    end
    return
end

# ── Les réglages d'un bloc ───────────────────────────────────────────

# (nom, bas, haut, valeur, ligne, première colonne, dernière colonne)
const BlockKnob = Tuple{String,Float64,Float64,Float64,Int,Int,Int}

# La colonne `col1` (1 = premier caractère) est-elle dans une chaîne ?
_in_string(chars, col1::Int) = isodd(count(==('"'), @view chars[1:min(col1 - 1, length(chars))]))

"""
    _block_knobs(ed, r1, r2) -> Vector{BlockKnob}

Les nombres du bloc qui sont des réglages connus (`gain(0.8)`, `lpf(900)`),
dans l'ordre du texte. Les notes d'une mini-notation n'en sont pas.
"""
function _block_knobs(ed::TK.CodeEditor, r1::Int, r2::Int)
    out = BlockKnob[]
    for row in r1:min(r2, length(ed.lines))
        chars = ed.lines[row]
        line = String(chars)
        for mt in eachmatch(_NUMBER_RX, line)
            (c1, c2) = _char_span(line, mt)
            _in_string(chars, c1 + 1) && continue
            v = tryparse(Float64, mt.match)
            v === nothing && continue
            fn = _enclosing_call(chars, c1)
            r = get(_PATTERN_KNOB_RANGES, fn, nothing)
            r === nothing && continue
            push!(out, (fn, r[1], r[2], v, row, c1, c2))
        end
    end
    return out
end

const _KNOB_ROW_BAR = 8

# « gain ━━━━━●━━ »
function _knob_row_text(k::BlockKnob)
    pos = clamp(round(Int, _knob_position(k[4], k[2], k[3]) * (_KNOB_ROW_BAR - 1)), 0, _KNOB_ROW_BAR - 1)
    return k[1] * " " * repeat('━', pos) * "●" * repeat('━', _KNOB_ROW_BAR - 1 - pos)
end
