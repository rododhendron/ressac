# src/editor_comment.jl
# Commenter et décommenter, à la façon de vim (commentary) : `gcc` la ligne,
# `gc` suivi d'un mouvement. Dans un son écrit avec un maillon par ligne,
# commenter une ligne `|> …`, c'est court-circuiter ce maillon. Sur une
# ligne `@dN`, c'est couper le slot : le même geste que `m`.

_is_commented(line::AbstractString) = startswith(lstrip(line), "#")

"""
    _toggle_comment_lines(lines, r1, r2) -> Vector{String}

Les lignes `r1:r2` commentées — ou décommentées si elles le sont déjà
toutes (les lignes vides ne comptent pas). Le `# ` se pose à l'indentation
commune, pour que le bloc garde sa forme.
"""
function _toggle_comment_lines(lines::AbstractVector{<:AbstractString}, r1::Int, r2::Int)
    out = String[String(l) for l in lines]
    rows = [r for r in max(r1, 1):min(r2, length(out)) if !isempty(strip(out[r]))]
    isempty(rows) && return out
    if all(r -> _is_commented(out[r]), rows)
        for r in rows
            out[r] = replace(out[r], r"^(\s*)#\s?" => s"\1"; count = 1)
        end
    else
        indent = minimum(length(match(r"^\s*", out[r]).match) for r in rows)
        for r in rows
            out[r] = out[r][1:indent] * "# " * out[r][(indent + 1):end]
        end
    end
    return out
end

"""
    _comment_rows!(m, ed, r1, r2)

Commente / décommente les lignes `r1:r2` de l'éditeur. Sur un seul bloc
`@dN` du texte des patterns, c'est `m` : la ligne est commentée ET le slot
coupé (ou rendu).
"""
function _comment_rows!(m::RessacApp, ed::TK.CodeEditor, r1::Int, r2::Int)
    n = length(ed.lines)
    (r1, r2) = (clamp(min(r1, r2), 1, n), clamp(max(r1, r2), 1, n))
    lines = [String(l) for l in ed.lines]
    if ed === _patterns_editor(m)
        (a, b) = _logical_block_range(lines, r1)
        # La ligne `@dN` elle-même : c'est le slot qu'on coupe. Une ligne
        # `|> …` plus bas dans le bloc : c'est ce maillon qu'on court-circuite.
        if r1 == a && r2 <= b && match(_SLOT_HEAD_RX, lines[a]) !== nothing
            ed.cursor_row = r1
            _toggle_mute_current_line!(m)
            return
        end
    end
    row, col = ed.cursor_row, ed.cursor_col
    _edit_text!(ed, join(_toggle_comment_lines(lines, r1, r2), '\n'); row = row, col = col)
    return
end

# `gc` attend son mouvement : `c` la ligne, `j` / `k` avec la voisine,
# `ap` / `ip` le paragraphe. Toute autre touche annule.
function _pending_gc_engine!(m::RessacApp, evt::TK.KeyEvent)
    evt.action === TK.key_press || return true
    pending = m.pending_gc
    m.pending_gc = nothing
    ed = _active_editor(m)
    (ed === nothing || evt.key !== :char) && return true
    row = ed.cursor_row
    c = evt.char
    if pending == "" && c == 'c'
        _comment_rows!(m, ed, row, row)
    elseif pending == "" && c == 'j'
        _comment_rows!(m, ed, row, row + 1)
    elseif pending == "" && c == 'k'
        _comment_rows!(m, ed, row - 1, row)
    elseif pending == "" && c in ('a', 'i')
        m.pending_gc = string(c)                         # un objet texte suit
    elseif pending in ("a", "i") && c == 'p'
        (a, b) = _paragraph_rows(ed, row)
        _comment_rows!(m, ed, a, b)
    end
    return true
end

# Le paragraphe autour de `row` : les lignes non vides qui se touchent.
function _paragraph_rows(ed::TK.CodeEditor, row::Int)
    n = length(ed.lines)
    blank(r) = isempty(strip(String(ed.lines[r])))
    (1 <= row <= n && !blank(row)) || return (row, row)
    a = row; b = row
    while a > 1 && !blank(a - 1); a -= 1; end
    while b < n && !blank(b + 1); b += 1; end
    return (a, b)
end

# `:format` — la mise en forme du son du curseur, annulable d'un `u`.
function _format_current_synth!(m::RessacApp)
    snd = _current_sound(m)
    snd === nothing && (_push_app_log!(m, "[ERROR] :format — pose le curseur sur un son (un bloc @synth)"); return)
    old = _sound_text(snd)
    new = String(rstrip(format_synth_text(old), '\n'))
    new == old && (_push_app_log!(m, "[INFO] :format — rien à changer"); return)
    _sound_write!(snd, new; row = 1, col = 0)
    _push_app_log!(m, "[INFO] :format — un maillon par ligne, nombres raccourcis (u annule)")
    return
end
