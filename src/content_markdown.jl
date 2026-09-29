# src/content_markdown.jl
# Rendu markdown partagé par le wiki et les fiches de doc : des lignes
# source vers des lignes écran de `Tachikoma.Span`, repliées à la largeur
# demandée, prêtes pour un `ScrollPane`. Une seule implémentation, pour
# que « ce qui est en `code` » ou « ce qui est **en gras** » se lise
# pareil partout.
#
# Pourquoi pas `Tachikoma.markdown_to_spans` (extension CommonMark) ?
# Essayé sur nos pages : pas de tableaux, des lignes qui débordent de la
# largeur (listes, paragraphes à plusieurs segments), pas de retrait
# suspendu. On garde donc la mise en page ici, sur les mêmes types, et
# la coloration du code vient du tokenizer de l'éditeur.
#
# Ce qu'on comprend : titres (#, ##, ###), listes à puces et numérotées
# avec retrait suspendu et continuation sur plusieurs lignes source,
# citations (>), filets (---), tableaux (| a | b |) ajustés à la largeur
# avec cellules repliées, blocs de code ``` colorés, et dans le texte :
# `code`, **gras**, *italique*, [lien](url).

const _MdLine = Vector{TK.Span}

_md_plain(s::AbstractString, sty::TK.Style = TK.tstyle(:text)) = TK.Span[TK.Span(String(s), sty)]
_md_text(line::_MdLine) = join(sp.content for sp in line)
_md_width(line::_MdLine) = sum(sp -> textwidth(sp.content), line; init = 0)

# ── Styles inline ────────────────────────────────────────────────────
_md_style(kind::Symbol) =
    kind === :code   ? TK.tstyle(:primary) :
    kind === :bold   ? TK.tstyle(:text_bright, bold = true) :
    kind === :italic ? TK.tstyle(:text, italic = true) :
    kind === :link   ? TK.tstyle(:secondary, underline = true) :
                       TK.tstyle(:text)

"""
    _md_inline(s; base) -> Vector{Span}

Découpe une ligne de texte en segments : `code`, **gras**, *italique*,
[texte](url) (l'URL disparaît, le texte reste souligné). Un `*` collé à
une espace ou à l'intérieur d'un mot (`bd*3`) n'ouvre rien.
"""
function _md_inline(s::AbstractString; base::TK.Style = TK.tstyle(:text))
    out = TK.Span[]
    cs = collect(String(s))
    n = length(cs)
    buf = IOBuffer()
    flush!() = (position(buf) > 0 && push!(out, TK.Span(String(take!(buf)), base)); nothing)
    i = 1
    while i <= n
        c = cs[i]
        if c == '`'
            j = findnext(==('`'), cs, i + 1)
            if j !== nothing
                flush!(); push!(out, TK.Span(String(cs[i+1:j-1]), _md_style(:code))); i = j + 1; continue
            end
        elseif c == '*' && i + 1 <= n && cs[i+1] == '*'
            j = _md_find_close(cs, i + 2, "**")
            if j !== nothing
                flush!(); append!(out, _md_inline(String(cs[i+2:j-1]); base = _md_style(:bold)))
                i = j + 2; continue
            end
        elseif c == '*' && i + 1 <= n && !isspace(cs[i+1]) && (i == 1 || !(isletter(cs[i-1]) || isdigit(cs[i-1])))
            j = _md_find_close(cs, i + 1, "*")
            if j !== nothing && !isspace(cs[j-1])
                flush!(); append!(out, _md_inline(String(cs[i+1:j-1]); base = _md_style(:italic)))
                i = j + 1; continue
            end
        elseif c == '[' && (i == 1 || cs[i-1] != '!')
            j = findnext(==(']'), cs, i + 1)
            if j !== nothing && j + 1 <= n && cs[j+1] == '('
                k = findnext(==(')'), cs, j + 2)
                if k !== nothing
                    flush!(); push!(out, TK.Span(String(cs[i+1:j-1]), _md_style(:link))); i = k + 1; continue
                end
            end
        end
        print(buf, c); i += 1
    end
    flush!()
    isempty(out) && push!(out, TK.Span("", base))
    return out
end

# Position du prochain `mark` à partir de `from`, hors segments en `code`.
function _md_find_close(cs::Vector{Char}, from::Int, mark::AbstractString)
    m = collect(mark); L = length(m); n = length(cs)
    i = from
    while i + L - 1 <= n
        if cs[i] == '`'
            j = findnext(==('`'), cs, i + 1)
            j === nothing && return nothing
            i = j + 1; continue
        end
        cs[i:i+L-1] == m && return i
        i += 1
    end
    return nothing
end

# ── Repli d'une ligne de segments ────────────────────────────────────
"""
    _md_wrap(spans, width; indent = 0) -> Vector{_MdLine}

Replie des segments à `width` colonnes en coupant aux espaces ; les
lignes suivantes reprennent avec `indent` espaces (retrait suspendu des
listes). Un mot plus long que la ligne est coupé. Les segments voisins
de même style sont recollés.
"""
function _md_wrap(spans::Vector{TK.Span}, width::Int; indent::Int = 0)
    width = max(4, width)
    words = TK.Span[]                        # mots et espaces, dans l'ordre, avec leur style
    for sp in spans
        for m in eachmatch(r"\s+|\S+", sp.content)
            push!(words, TK.Span(m.match, sp.style))
        end
    end
    lines = _MdLine[]
    cur = TK.Span[]; cur_w = 0
    pad = TK.Span(" " ^ indent, TK.tstyle(:text))
    function newline!()
        while !isempty(cur) && all(isspace, cur[end].content); pop!(cur); end   # pas d'espace en fin de ligne
        push!(lines, cur); cur = TK.Span[]; cur_w = 0
        return
    end
    first_tok = true
    for sp in words
        w = sp.content
        if all(isspace, w)
            # Pas d'espace en tête de ligne ni au-delà de la largeur — sauf
            # le retrait voulu du tout premier segment (préfixe de liste).
            if first_tok
                push!(cur, sp); cur_w += textwidth(w); first_tok = false; continue
            end
            (isempty(cur) || cur_w + textwidth(w) > width) && continue
            push!(cur, sp); cur_w += textwidth(w); continue
        end
        first_tok = false
        tw = textwidth(w)
        cur_w + tw > width && !isempty(cur) && newline!()
        if isempty(cur) && !isempty(lines) && indent > 0
            push!(cur, pad); cur_w = indent
        end
        # Mot trop long pour la place restante et pour une ligne entière : on le tranche.
        while tw > max(1, width - cur_w) && tw > max(1, width - (isempty(lines) ? 0 : indent))
            part = _md_take(w, max(1, width - cur_w))
            push!(cur, TK.Span(part, sp.style)); cur_w += textwidth(part)
            w = w[nextind(w, 0, length(part) + 1):end]; tw = textwidth(w)
            newline!()
            indent > 0 && (push!(cur, pad); cur_w = indent)
        end
        push!(cur, TK.Span(w, sp.style)); cur_w += tw
    end
    while !isempty(cur) && all(isspace, cur[end].content); pop!(cur); end
    (!isempty(cur) || isempty(lines)) && push!(lines, cur)
    return map(_md_merge, lines)
end

# Recolle les segments voisins de même style (le repli travaille mot à mot).
function _md_merge(line::_MdLine)
    out = TK.Span[]
    for sp in line
        if !isempty(out) && out[end].style == sp.style
            out[end] = TK.Span(out[end].content * sp.content, sp.style)
        else
            push!(out, sp)
        end
    end
    return out
end

# Les premiers caractères de `s` qui tiennent dans `w` colonnes.
function _md_take(s::AbstractString, w::Int)
    io = IOBuffer(); used = 0
    for c in s
        cw = textwidth(c)
        used + cw > w && break
        print(io, c); used += cw
    end
    return String(take!(io))
end

# Coupe une ligne de segments à `width` colonnes, avec une ellipse.
function _md_clip(line::_MdLine, width::Int)
    _md_width(line) <= width && return line
    out = TK.Span[]; used = 0
    for sp in line
        room = width - 1 - used
        room <= 0 && break
        part = textwidth(sp.content) <= room ? sp.content : _md_take(sp.content, room)
        push!(out, TK.Span(part, sp.style)); used += textwidth(part)
        textwidth(sp.content) > room && break
    end
    push!(out, TK.Span("…", TK.tstyle(:text_dim)))
    return out
end

# ── Code : coloration par le tokenizer de l'éditeur ──────────────────
"""
    _md_code_line(s, width) -> _MdLine

Une ligne de code Julia colorée comme dans l'éditeur (mêmes tokens,
mêmes styles), rognée à `width`.
"""
function _md_code_line(s::AbstractString, width::Int)
    cs = collect(String(s))
    out = TK.Span[]
    toks = try TK.tokenize_line(cs) catch; TK.Token[] end
    pos = 1
    for t in toks
        t.start > pos && push!(out, TK.Span(String(cs[pos:t.start-1]), TK.tstyle(:text)))
        push!(out, TK.Span(String(cs[t.start:t.stop]), TK.token_style(t.kind)))
        pos = t.stop + 1
    end
    pos <= length(cs) && push!(out, TK.Span(String(cs[pos:end]), TK.tstyle(:text)))
    isempty(out) && push!(out, TK.Span("", TK.tstyle(:text)))
    return _md_clip(out, width)
end

# ── Tableaux ─────────────────────────────────────────────────────────
_md_is_table_row(s::AbstractString) = startswith(strip(s), "|")
_md_is_table_sep(s::AbstractString) = occursin(r"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$", s)

# Les cellules d'une ligne : coupées aux `|` hors code (`|>` dans un
# `code` reste dans sa cellule) ; `\|` est un vrai `|`.
function _md_table_cells(s::AbstractString)
    t = strip(s)
    startswith(t, "|") && (t = t[nextind(t, 1):end])
    endswith(t, "|") && (t = t[1:prevind(t, lastindex(t))])
    cells = String[]; io = IOBuffer(); in_code = false; esc = false
    for c in t
        if esc
            c == '|' || print(io, '\\')
            print(io, c); esc = false; continue
        end
        c == '\\' && (esc = true; continue)
        c == '`' && (in_code = !in_code)
        if c == '|' && !in_code
            push!(cells, String(strip(String(take!(io)))))
        else
            print(io, c)
        end
    end
    esc && print(io, '\\')
    push!(cells, String(strip(String(take!(io)))))
    return cells
end

"""
    _md_table(rows, width) -> Vector{_MdLine}

Un tableau ajusté à la largeur : colonnes larges comme leur contenu
quand ça tient, sinon les plus larges sont resserrées et leurs cellules
se replient sur plusieurs lignes. L'en-tête est en gras, suivi d'un filet.
"""
function _md_table(rows::Vector{String}, width::Int)
    cells = [_md_table_cells(r) for r in rows if !_md_is_table_sep(r)]
    isempty(cells) && return _MdLine[]
    ncol = maximum(length, cells)
    for c in cells; while length(c) < ncol; push!(c, ""); end; end
    spans = [[_md_inline(c) for c in row] for row in cells]
    widths = [maximum(r -> _md_width(r[j]), spans) for j in 1:ncol]
    gap = 2
    budget = max(ncol * 4, width - gap * (ncol - 1))
    # Resserre d'abord la colonne qui a le plus de marge au-dessus de son
    # mot le plus long (pour ne pas couper « Intervalle » en deux), puis,
    # s'il faut encore, la plus large.
    longest = [maximum(r -> maximum(textwidth, split(_md_text(r[j]), ' '; keepempty = false); init = 1), spans)
               for j in 1:ncol]
    while sum(widths) > budget && maximum(widths) > 4
        slack = widths .- longest
        j = maximum(slack) > 0 ? argmax(slack) : argmax(widths)
        widths[j] -= 1
    end
    total = min(width, sum(widths) + gap * (ncol - 1))
    head = TK.tstyle(:text_bright, bold = true)
    out = _MdLine[]
    for (i, row) in enumerate(spans)
        # Chaque cellule repliée à sa colonne ; la ligne fait la hauteur de la plus haute.
        wrapped = [_md_wrap(i == 1 ? [TK.Span(sp.content, head) for sp in row[j]] : row[j], widths[j])
                   for j in 1:ncol]
        height = maximum(length, wrapped)
        for k in 1:height
            line = TK.Span[]
            for j in 1:ncol
                cell = k <= length(wrapped[j]) ? _md_clip(wrapped[j][k], widths[j]) : TK.Span[]
                append!(line, cell)
                j < ncol && push!(line, TK.Span(" " ^ (widths[j] - _md_width(cell) + gap), TK.tstyle(:text)))
            end
            push!(out, _md_merge(line))
        end
        i == 1 && push!(out, _md_plain("─" ^ total, TK.tstyle(:border)))
    end
    return out
end

# ── Blocs ────────────────────────────────────────────────────────────
# Les sources sont coupées à ~72 colonnes à la main : un paragraphe, un
# élément de liste ou une citation s'étendent sur plusieurs lignes. On
# regroupe donc d'abord en blocs, puis chaque bloc est replié à la
# largeur de la pane — le gras ou le code qui enjambe deux lignes
# source tient alors d'un seul tenant.
struct _MdBlock
    kind::Symbol          # :para, :bullet, :number, :quote, :heading, :rule, :blank, :fence, :code, :table
    text::String          # texte joint (ligne brute pour :code, lignes jointes par \n pour :table)
    level::Int            # niveau de titre, retrait de liste
    label::String         # numéro d'une liste numérotée
end

const _MD_BULLET_RX = r"^(\s*)([-*+])\s+(.*)$"
const _MD_NUMBER_RX = r"^(\s*)(\d+)[.)]\s+(.*)$"

"""
    _md_blocks(lines) -> Vector{_MdBlock}

Regroupe les lignes source en blocs. Une ligne non vide qui suit un
paragraphe, un élément de liste ou une citation le continue ; une ligne
vide, un titre, un filet, une clôture de code ou une ligne de tableau
le termine.
"""
function _md_blocks(lines::AbstractVector{<:AbstractString})
    out = _MdBlock[]
    in_code = false
    open_kind = :none                     # bloc textuel en cours (:para, :bullet, :number, :quote)
    close!() = (open_kind = :none; nothing)
    for raw in lines
        s = String(raw); t = strip(s)
        if in_code
            if startswith(t, "```")
                in_code = false; push!(out, _MdBlock(:fence, "", 0, ""))
            else
                push!(out, _MdBlock(:code, s, 0, ""))
            end
            continue
        end
        if startswith(t, "```")
            close!(); in_code = true; push!(out, _MdBlock(:fence, "", 0, "")); continue
        end
        if isempty(t)
            close!(); push!(out, _MdBlock(:blank, "", 0, "")); continue
        end
        if _md_is_table_row(s)
            if !isempty(out) && out[end].kind === :table
                out[end] = _MdBlock(:table, out[end].text * "\n" * s, 0, "")
            else
                close!(); push!(out, _MdBlock(:table, s, 0, ""))
            end
            continue
        end
        if occursin(r"^-{3,}$|^\*{3,}$", t)
            close!(); push!(out, _MdBlock(:rule, "", 0, "")); continue
        end
        if (m = match(r"^(#{1,3})\s+(.*)$", t)) !== nothing
            close!(); push!(out, _MdBlock(:heading, String(m.captures[2]), length(m.captures[1]), "")); continue
        end
        if startswith(t, ">")
            body = strip(t[2:end])
            if open_kind === :quote
                out[end] = _MdBlock(:quote, out[end].text * " " * body, 0, "")
            else
                close!(); push!(out, _MdBlock(:quote, String(body), 0, "")); open_kind = :quote
            end
            continue
        end
        if (m = match(_MD_BULLET_RX, s)) !== nothing
            close!(); push!(out, _MdBlock(:bullet, String(m.captures[3]), length(m.captures[1]), "")); open_kind = :bullet
            continue
        end
        if (m = match(_MD_NUMBER_RX, s)) !== nothing
            close!(); push!(out, _MdBlock(:number, String(m.captures[3]), length(m.captures[1]), String(m.captures[2]))); open_kind = :number
            continue
        end
        if open_kind !== :none
            b = out[end]
            out[end] = _MdBlock(b.kind, b.text * " " * t, b.level, b.label)
        else
            push!(out, _MdBlock(:para, String(t), 0, "")); open_kind = :para
        end
    end
    in_code && push!(out, _MdBlock(:fence, "", 0, ""))
    return out
end

"""
    _md_render(lines, width) -> Vector{_MdLine}

Les lignes source d'un document markdown, rendues en lignes écran de
`width` colonnes au plus — le contenu d'un `ScrollPane`.
"""
function _md_render(lines::AbstractVector{<:AbstractString}, width::Int)
    out = _MdLine[]
    width = max(8, width)
    fence = _md_plain("┄" * "─" ^ max(0, width - 1), TK.tstyle(:border))
    for b in _md_blocks(lines)
        if b.kind === :blank
            push!(out, TK.Span[])
        elseif b.kind === :fence
            push!(out, fence)
        elseif b.kind === :code
            push!(out, _md_code_line(b.text, width))
        elseif b.kind === :table
            append!(out, _md_table(String.(split(b.text, '\n')), width))
        elseif b.kind === :rule
            push!(out, _md_plain("─" ^ width, TK.tstyle(:border)))
        elseif b.kind === :heading
            pre, sty = b.level == 1 ? ("▓ ", TK.tstyle(:accent, bold = true)) :
                       b.level == 2 ? ("» ", TK.tstyle(:primary, bold = true)) :
                                      ("",   TK.tstyle(:title, bold = true))
            append!(out, _md_wrap(_md_inline(pre * b.text; base = sty), width; indent = textwidth(pre)))
        elseif b.kind === :quote
            for l in _md_wrap(_md_inline(b.text; base = TK.tstyle(:text, italic = true)), width - 2)
                push!(out, vcat(TK.Span[TK.Span("▎ ", TK.tstyle(:accent))], l))
            end
        elseif b.kind === :bullet
            pre = " " ^ (b.level ÷ 2 * 2 + 2) * "• "
            body = vcat(TK.Span[TK.Span(pre, TK.tstyle(:accent))], _md_inline(b.text))
            append!(out, _md_wrap(body, width; indent = textwidth(pre)))
        elseif b.kind === :number
            pre = " " ^ (b.level ÷ 3 * 3 + 2) * b.label * ". "
            body = vcat(TK.Span[TK.Span(pre, TK.tstyle(:accent, bold = true))], _md_inline(b.text))
            append!(out, _md_wrap(body, width; indent = textwidth(pre)))
        else
            append!(out, _md_wrap(_md_inline(b.text), width))
        end
    end
    return out
end

# ── Le ScrollPane qui porte un document ──────────────────────────────
"""
    _md_scrollpane(; offset = 0) -> Tachikoma.ScrollPane

Le `ScrollPane` d'un document : pas de cadre (la pane dessine le sien),
pas de suivi automatique, une barre de défilement quand ça déborde,
molette et clic sur la barre gérés par Tachikoma.
"""
_md_scrollpane(; offset::Int = 0) =
    TK.ScrollPane(_MdLine[]; offset = max(0, offset), following = false, show_scrollbar = true)

# Fait défiler un ScrollPane comme une touche de Tachikoma le ferait.
_md_scroll!(sp::TK.ScrollPane, key::Symbol) = (TK.handle_key!(sp, TK.KeyEvent(key)); nothing)
