# src/pane_wiki.jl
# Pane wiki — le wiki (docs/wiki/*.md) à côté des patterns, plus un modal.
# Table des matières à gauche quand la pane est assez large, contenu à
# droite ; en pane étroite, seul le contenu avec la page en titre.

mutable struct WikiPane <: PaneImpl
    pages::Vector{_WikiPage}
    idx::Int
    scroll::Int
end

function _wiki_pane_ctor(args::AbstractDict)
    pages = _load_wiki_pages()
    idx = clamp(Int(get(args, "idx", 1)), 1, max(1, length(pages)))
    return WikiPane(pages, idx, max(0, Int(get(args, "scroll", 0))))
end

_wiki_last(p::WikiPane) = isempty(p.pages) ? 0 : max(0, length(p.pages[p.idx].lines) - 1)

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
        p.idx = n; p.scroll = 0
        return true
    end
    i = findfirst(pg -> occursin(q, lowercase(pg.title)), p.pages)
    i === nothing && return false
    p.idx = i; p.scroll = 0
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
    _render_pane_block_simple!(rect, "WIKI · $(p.idx)/$(length(p.pages)) $(page.title)", buf)
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
    visible = page.lines[max(1, p.scroll + 1):end]
    in_code = isodd(count(l -> startswith(strip(l), "```"), page.lines[1:min(p.scroll, length(page.lines))]))
    for (i, line) in enumerate(visible)
        i > inner.height && break
        if startswith(strip(line), "```")
            in_code = !in_code
            TK.set_string!(buf, content_x, inner.y + i - 1,
                           first(rpad("┄" * "─" ^ max(0, content_w - 1), content_w), content_w),
                           TK.tstyle(:border))
            continue
        end
        _render_markdown_line!(line, buf, content_x, inner.y + i - 1, content_w; in_code = in_code)
    end
    return nothing
end

handle_key!(p::WikiPane, evt) = evt isa TK.KeyEvent && dispatch!(((:wiki, p),), evt)
pane_scope(::WikiPane) = :wiki
title(p::WikiPane) = isempty(p.pages) ? "wiki" : "wiki:$(p.pages[p.idx].title)"
serialize(p::WikiPane) = Dict{String,Any}("idx" => p.idx, "scroll" => p.scroll)
register_pane_kind!(:wiki, _wiki_pane_ctor)

scope!(:wiki, "Wiki (pane)")
bind!(:wiki, ["j", "↓"], "défiler"; group = :nav, repeat = true,
      action = p -> (p.scroll = min(p.scroll + 1, _wiki_last(p))))
bind!(:wiki, ["k", "↑"], "remonter"; group = :nav, repeat = true, when = p -> p.scroll > 0,
      action = p -> (p.scroll = max(0, p.scroll - 1)))
bind!(:wiki, ["n", "]", "→"], "page suivante"; group = :nav,
      action = p -> (isempty(p.pages) || (p.idx = mod1(p.idx + 1, length(p.pages)); p.scroll = 0)))
bind!(:wiki, ["p", "[", "←"], "page précédente"; group = :nav,
      action = p -> (isempty(p.pages) || (p.idx = mod1(p.idx - 1, length(p.pages)); p.scroll = 0)))
bind!(:wiki, "d", "10 lignes plus bas"; group = :nav, hint = false, repeat = true,
      action = p -> (p.scroll = min(p.scroll + 10, _wiki_last(p))))
bind!(:wiki, "u", "10 lignes plus haut"; group = :nav, hint = false, repeat = true,
      action = p -> (p.scroll = max(0, p.scroll - 10)))
bind!(:wiki, ["g", "G"], "début / fin de page"; group = :nav, hint = false,
      action = (p, evt) -> (p.scroll = evt.char == 'g' ? 0 : _wiki_last(p)))
bind!(:wiki, ["1", "2", "3", "4", "5", "6", "7", "8", "9"], "aller à la page N"; group = :nav, hint = false,
      action = (p, evt) -> (n = Int(evt.char - '0');
                            1 <= n <= length(p.pages) && (p.idx = n; p.scroll = 0)))
