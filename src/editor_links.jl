# src/editor_links.jl
# Le maillon — une étape d'une chaîne de `|>` — comme objet texte de vim :
# `m`, à côté de `w` (mot) et `p` (paragraphe).
#
#   dam   retire le maillon (et son `|>`) : le signal passe tout droit
#   dim   vide le maillon, garde le `|>`
#   yam   le copie ; `p` le pose ailleurs, même dans un autre son
#   cim   le remplace : l'atelier propose ses cousins (atelier.jl)
#
# Un maillon par ligne (la forme que `:format` donne) : `am` est la ligne.
# Plusieurs sur une ligne : `am` prend le maillon et un `|>` voisin.
# Vaut dans un son comme dans un bloc de pattern.

# Où finit le code d'une ligne (avant son commentaire), en caractères.
function _code_length(chars::Vector{Char})
    in_str = false
    i = 1
    while i <= length(chars)
        c = chars[i]
        if in_str
            c == '\\' && (i += 1)
            c == '"' && (in_str = false)
        elseif c == '"'
            in_str = true
        elseif c == '#'
            return i - 1
        end
        i += 1
    end
    return length(chars)
end

# Les positions des `|>` de premier niveau (hors parenthèses, crochets et
# chaînes) dans les `n` premiers caractères.
function _pipe_positions(chars::Vector{Char}, n::Int = length(chars))
    out = Int[]
    depth = 0
    in_str = false
    i = 1
    while i <= n
        c = chars[i]
        if in_str
            c == '\\' && (i += 1)
            c == '"' && (in_str = false)
        elseif c == '"'
            in_str = true
        elseif c in ('(', '[', '{')
            depth += 1
        elseif c in (')', ']', '}')
            depth -= 1
        elseif c == '|' && depth == 0 && i < n && chars[i + 1] == '>'
            push!(out, i)
            i += 1
        end
        i += 1
    end
    return out
end

"""
    _line_links(chars, row) -> Vector{LinkSpan}

Les maillons d'une ligne, de gauche à droite. Vide pour une ligne sans code.
"""
function _line_links(chars::Vector{Char}, row::Int = 0)
    n = _code_length(chars)
    while n >= 1 && isspace(chars[n]); n -= 1; end
    n == 0 && return LinkSpan[]
    start = findfirst(!isspace, chars)
    pipes = _pipe_positions(chars, n)
    # Les segments entre les pipes : (début, fin, pipe qui le précède ou 0).
    segs = Tuple{Int,Int,Int}[]
    prev = start
    prev_pipe = 0
    for p in vcat(pipes, n + 1)
        (a, b) = (prev, p - 1)
        while a <= b && isspace(chars[a]); a += 1; end
        while b >= a && isspace(chars[b]); b -= 1; end
        a <= b && push!(segs, (a, b, prev_pipe))
        prev = p + 2
        prev_pipe = p
    end
    out = LinkSpan[]
    for (k, (a, b, pipe)) in enumerate(segs)
        linewise = length(segs) == 1
        around = if pipe > 0
            # avec son `|>`, et l'espace qui le précède s'il n'ouvre pas la ligne
            lead = (pipe > start && pipe > 1 && isspace(chars[pipe - 1])) ? pipe - 1 : pipe
            lead:b
        elseif k < length(segs)
            a:(segs[k + 1][1] - 1)                 # le premier de la ligne : avec le `|>` qui le suit
        else
            a:b
        end
        mt = match(r"^[A-Za-z_][A-Za-z0-9_!]*", String(chars[a:b]))
        push!(out, LinkSpan(row, a:b, around, linewise, pipe > 0, mt === nothing ? "" : String(mt.match)))
    end
    return out
end

"""
    _link_at(ed, row, col) -> Union{Nothing,LinkSpan}

Le maillon sous le curseur (`col` compté depuis 0, comme le curseur) : celui
qui le contient, sinon le plus proche sur la ligne.
"""
function _link_at(ed::TK.CodeEditor, row::Int = ed.cursor_row, col::Int = ed.cursor_col)
    1 <= row <= length(ed.lines) || return nothing
    links = _line_links(ed.lines[row], row)
    isempty(links) && return nothing
    x = col + 1
    for l in links
        (first(l.around) <= x <= last(l.around)) && return l
    end
    return links[argmin([min(abs(x - first(l.inner)), abs(x - last(l.inner))) for l in links])]
end

# Ce qu'on vient de copier vaut dans tous les textes ouverts : un maillon
# copié dans un son se pose dans un autre.
function _share_yank!(m::RessacApp, from::TK.CodeEditor)
    ws = current_workspace(m.workspaces)
    ws === nothing && return
    nodes = LayoutNode[ws.tree]
    append!(nodes, values(m.volets))
    for node in nodes, leaf in _all_leaves(node), tab in leaf.tabs
        tab isa EditorPane || continue
        for b in tab.tabs
            b.code_editor === from && continue
            b.code_editor.yank_buffer = [copy(l) for l in from.yank_buffer]
            b.code_editor.yank_is_linewise = from.yank_is_linewise
        end
    end
    return
end

"""
    _link_op!(m, ed, op, kind)

`d` / `y` / `c` appliqué au maillon sous le curseur ; `kind` vaut `'a'`
(avec son `|>`) ou `'i'` (son texte seul).
"""
function _link_op!(m::RessacApp, ed::TK.CodeEditor, op::Char, kind::Char)
    link = _link_at(ed)
    if link === nothing
        _push_app_log!(m, "[INFO] $(op)$(kind)m — pas de maillon sur cette ligne")
        return
    end
    if op == 'c'
        _atelier_open!(m, :replace)
        return
    end
    lines = _buffer_lines(ed)
    row = link.row
    whole = kind == 'a' && link.linewise
    range = kind == 'a' ? link.around : link.inner
    if whole
        ed.yank_buffer = [copy(lines[row])]
        ed.yank_is_linewise = true
    else
        ed.yank_buffer = [lines[row][range]]
        ed.yank_is_linewise = false
    end
    _share_yank!(m, ed)
    name = isempty(link.name) ? "maillon" : link.name
    if op == 'y'
        _push_app_log!(m, "[INFO] $name copié — p le pose")
        return
    end
    if whole
        deleteat!(lines, row)
        isempty(lines) && push!(lines, Char[])
        r = min(row, length(lines))
        _edit_lines!(ed, lines; row = r, col = something(findfirst(!isspace, lines[r]), 1) - 1)
    else
        lines[row] = vcat(lines[row][1:(first(range) - 1)], lines[row][(last(range) + 1):end])
        _edit_lines!(ed, lines; row = row, col = clamp(first(range) - 1, 0, max(length(lines[row]) - 1, 0)))
    end
    _push_app_log!(m, kind == 'a' ? "[INFO] $name retiré — le signal passe tout droit (u annule)" :
                                    "[INFO] $name vidé (u annule)")
    return
end

# Un opérateur (`d`, `c`, `y`) puis `a` ou `i` : l'objet texte suit. `m` est
# le maillon ; toute autre touche annule, sans être rejouée.
function _pending_obj_engine!(m::RessacApp, evt::TK.KeyEvent)
    evt.action === TK.key_press || return true
    (op, kind) = m.pending_obj
    m.pending_obj = nothing
    ed = _active_editor(m)
    (ed === nothing || evt.key !== :char) && return true
    evt.char == 'm' && _link_op!(m, ed, op, kind)
    return true
end

# Le curseur est-il sur une ligne de la chaîne d'un son : entre l'en-tête
# `@synth … begin` et son `end`, ou sur une ligne `|> …` ?
function _in_synth_chain(ed::TK.CodeEditor)
    row = ed.cursor_row
    1 <= row <= length(ed.lines) || return false
    startswith(lstrip(String(ed.lines[row])), "|>") && return true
    block = _synth_block_rows([String(l) for l in ed.lines])
    return block !== nothing && block[1] < row < block[2]
end
