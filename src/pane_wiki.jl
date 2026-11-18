# src/pane_wiki.jl
# Pane wiki — le wiki (docs/wiki/*.md) à côté des patterns, plus un modal.
# Table des matières à gauche quand la pane est assez large, contenu à
# droite ; en pane étroite, seul le contenu avec la page en titre.

mutable struct WikiPane <: PaneImpl
    pages::Vector{_WikiPage}
    idx::Int
    pane::TK.ScrollPane               # le contenu rendu, son défilement, sa barre
    rendered::Tuple{Int,Int,Int}      # (page, largeur, exemple) du contenu posé dans `pane`
    example::Int                      # l'exemple `@dN` désigné sur la page (0 : aucun)
end

WikiPane(pages::Vector{_WikiPage}, idx::Int, offset::Int = 0) =
    WikiPane(pages, clamp(idx, 1, max(1, length(pages))), _scrollpane(; offset), (0, 0, 0), 0)

# ── Les exemples d'une page ──────────────────────────────────────────
# Une ligne `@dN …` d'un bloc de code (et ses suites `|> …`) est un exemple
# qu'on peut poser dans ses patterns : `Tab` va au suivant, `Entrée` le pose.

# La pane ne connaît pas l'app : elle poste l'exemple, `_drain_requests!` le pose.
const _WIKI_POSE_REQUEST = Ref{Union{Nothing,String}}(nothing)

"""
    _wiki_examples(lines) -> Vector{String}

Les exemples `@dN` des blocs de code d'une page, dans l'ordre.
"""
function _wiki_examples(lines::Vector{String})
    out = String[]
    code = String[]
    in_code = false
    flush!() = begin
        (blocks, _) = _scan_slot_blocks(code)
        for b in blocks
            b.commented || push!(out, join(code[b.row:b.last_row], "\n"))
        end
        empty!(code)
    end
    for l in lines
        if startswith(strip(l), "```")
            in_code && flush!()
            in_code = !in_code
        elseif in_code
            push!(code, l)
        end
    end
    return out
end

_wiki_page_examples(p::WikiPane) = isempty(p.pages) ? String[] : _wiki_examples(p.pages[p.idx].lines)

# La ligne rendue où commence le k-ième exemple (0 si on ne la retrouve pas).
function _wiki_example_line(content, examples::Vector{String}, k::Int)
    from = 1
    found = 0
    for i in 1:k
        needle = strip(first(split(examples[i], '\n')))
        found = 0
        for j in from:length(content)
            if occursin(needle, join(sp.content for sp in content[j]))
                found = j; break
            end
        end
        found == 0 && return 0
        from = found + 1
    end
    return found
end

# Tab / S-Tab : l'exemple suivant / précédent de la page, amené à l'écran.
function _wiki_example_move!(p::WikiPane, dir::Int)
    n = length(_wiki_page_examples(p))
    n == 0 && return
    p.example = p.example == 0 ? (dir > 0 ? 1 : n) : mod1(p.example + dir, n)
    p.rendered = (0, 0, 0)                               # à refaire, avec l'exemple marqué
    return
end

function _wiki_example_pose!(p::WikiPane)
    ex = _wiki_page_examples(p)
    1 <= p.example <= length(ex) || return
    _WIKI_POSE_REQUEST[] = ex[p.example]
    return
end

function _wiki_pane_ctor(args::AbstractDict)
    return WikiPane(_load_wiki_pages(), Int(get(args, "idx", 1)), Int(get(args, "scroll", 0)))
end

# Pose dans le ScrollPane la page courante rendue à `width` colonnes,
# une fois par (page, largeur).
function _wiki_sync!(p::WikiPane, width::Int)
    isempty(p.pages) && return
    p.rendered == (p.idx, width, p.example) && return
    content = _md_render(p.pages[p.idx].lines, width)
    if p.example > 0
        ex = _wiki_page_examples(p)
        j = p.example <= length(ex) ? _wiki_example_line(content, ex, p.example) : 0
        if j > 0
            # L'exemple désigné ressort, sur toutes ses lignes, et vient à l'écran.
            for r in j:min(length(content), j + count(==('\n'), ex[p.example]))
                content[r] = TK.Span[TK.Span(sp.content, TK.tstyle(:accent, bold = true)) for sp in content[r]]
            end
            p.pane.offset = max(0, j - 4)
        end
    end
    TK.set_content!(p.pane, content)
    p.rendered = (p.idx, width, p.example)
    return
end

# La dernière position de défilement (le bas du contenu visible), telle
# que le ScrollPane la calcule après un rendu.
_wiki_last(p::WikiPane) = _scroll_last(p.pane)

# Changer de page : le défilement repart du haut.
function _wiki_show!(p::WikiPane, idx::Int)
    p.idx = idx; p.pane.offset = 0; p.example = 0
    return
end

"""
    _wiki_goto!(p, query) -> Bool

Va à la page `query` : un numéro (`3`) ou un morceau de titre
(`patterns`, `tidal`), sans tenir compte de la casse.
"""
function _wiki_goto!(p::WikiPane, query::AbstractString)
    q = lowercase(strip(query))
    isempty(q) && return false
    n = tryparse(Int, q)
    if n !== nothing
        1 <= n <= length(p.pages) || return false
        _wiki_show!(p, n)
        return true
    end
    i = findfirst(pg -> occursin(q, lowercase(pg.title)), p.pages)
    i === nothing && return false
    _wiki_show!(p, i)
    return true
end

function render!(p::WikiPane, area, buf)
    rect = TK.Rect(area.x, area.y, area.width, area.height)
    if isempty(p.pages)
        _render_pane_block_simple!(rect, "WIKI", buf)
        inner = _inner_rect_simple(rect)
        inner.height >= 1 && TK.set_string!(buf, inner.x, inner.y,
            first("(aucune page dans docs/wiki/)", inner.width), TK.tstyle(:text_dim))
        return nothing
    end
    page = p.pages[p.idx]
    nex = length(_wiki_examples(page.lines))
    # L'état de l'exemple d'abord, et court : le cadre rogne un titre long
    # (la barre de touches dit « Entrée poser »).
    head = "WIKI · $(p.idx)/$(length(p.pages))" *
           (nex == 0 ? "" : p.example == 0 ? " · Tab : $nex ex." : " · ex. $(p.example)/$nex") *
           " · $(page.title)"
    _render_pane_block_simple!(rect, head, buf)
    inner = _inner_rect_simple(rect)
    (inner.height < 1 || inner.width < 10) && return nothing
    content_x = inner.x
    content_w = inner.width
    if inner.width >= 70
        toc_w = max(18, inner.width ÷ 4)
        for (i, pg) in enumerate(p.pages)
            i > inner.height && break
            is_cur = i == p.idx
            label = (is_cur ? "▶ " : "  ") * "$i. $(pg.title)"
            style = is_cur ? TK.tstyle(:accent, bold = true) : TK.tstyle(:text)
            TK.set_string!(buf, inner.x, inner.y + i - 1, first(rpad(label, toc_w - 1), toc_w - 1), style)
        end
        sep_x = inner.x + toc_w
        for y in inner.y:(inner.y + inner.height - 1)
            TK.set_string!(buf, sep_x, y, "│", TK.tstyle(:border))
        end
        content_x = sep_x + 2
        content_w = inner.width - toc_w - 2
    end
    # Le ScrollPane rend le contenu et sa barre ; il garde une colonne
    # pour la barre, d'où le rendu à content_w - 1.
    _wiki_sync!(p, max(8, content_w - 1))
    TK.render(p.pane, TK.Rect(content_x, inner.y, content_w, inner.height), buf)
    return nothing
end

handle_key!(p::WikiPane, evt) = evt isa TK.KeyEvent && dispatch!(((:wiki, p),), evt)
handle_mouse!(p::WikiPane, evt::TK.MouseEvent) = TK.handle_mouse!(p.pane, evt)   # molette, barre
pane_scope(::WikiPane) = :wiki
title(p::WikiPane) = isempty(p.pages) ? "wiki" : "wiki:$(p.pages[p.idx].title)"
serialize(p::WikiPane) = Dict{String,Any}("idx" => p.idx, "scroll" => p.pane.offset)
register_pane_kind!(:wiki, _wiki_pane_ctor)

scope!(:wiki, "Wiki (pane)"; modes = (:play,))   # le wiki est du côté des patterns
mixin_scroll_nav!(:wiki, p -> p.pane; page_synonyms = true, hint = true, labels = (down = "défiler", up = "remonter"))
bind!(:wiki, ["n", "]", "→"], "page du wiki suivante"; group = :nav,
      action = p -> (isempty(p.pages) || _wiki_show!(p, mod1(p.idx + 1, length(p.pages)))))
bind!(:wiki, ["p", "[", "←"], "page du wiki précédente"; group = :nav,
      action = p -> (isempty(p.pages) || _wiki_show!(p, mod1(p.idx - 1, length(p.pages)))))
bind!(:wiki, "Tab", "exemple suivant de la page"; short = "exemple", group = :nav, action = p -> _wiki_example_move!(p, +1))
bind!(:wiki, "S-Tab", "exemple précédent"; group = :nav, hint = false, action = p -> _wiki_example_move!(p, -1))
bind!(:wiki, "Enter", "poser l'exemple désigné dans les patterns, sur un slot libre"; short = "poser", group = :edit,
      when = p -> p.example > 0, action = _wiki_example_pose!)
bind!(:wiki, ["1", "2", "3", "4", "5", "6", "7", "8", "9"], "aller à la page N"; group = :nav, hint = false,
      action = (p, evt) -> (n = Int(evt.char - '0');
                            1 <= n <= length(p.pages) && _wiki_show!(p, n)))
