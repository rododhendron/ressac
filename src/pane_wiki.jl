# src/pane_wiki.jl
# Pane wiki — le wiki (docs/wiki/*.md) à côté des patterns, plus un modal.
# Table des matières à gauche quand la pane est assez large, contenu à
# droite ; en pane étroite, seul le contenu avec la page en titre.

mutable struct WikiPane <: PaneImpl
    pages::Vector{_WikiPage}
    idx::Int
    pane::TK.ScrollPane               # le contenu rendu, son défilement, sa barre
    rendered::Tuple{Int,Int}          # (page, largeur) du contenu posé dans `pane`
end

WikiPane(pages::Vector{_WikiPage}, idx::Int, offset::Int = 0) =
    WikiPane(pages, clamp(idx, 1, max(1, length(pages))), _scrollpane(; offset), (0, 0))

function _wiki_pane_ctor(args::AbstractDict)
    return WikiPane(_load_wiki_pages(), Int(get(args, "idx", 1)), Int(get(args, "scroll", 0)))
end

# Pose dans le ScrollPane la page courante rendue à `width` colonnes,
# une fois par (page, largeur).
function _wiki_sync!(p::WikiPane, width::Int)
    isempty(p.pages) && return
    p.rendered == (p.idx, width) && return
    TK.set_content!(p.pane, _md_render(p.pages[p.idx].lines, width))
    p.rendered = (p.idx, width)
    return
end

# La dernière position de défilement (le bas du contenu visible), telle
# que le ScrollPane la calcule après un rendu.
_wiki_last(p::WikiPane) = _scroll_last(p.pane)

# Changer de page : le défilement repart du haut.
function _wiki_show!(p::WikiPane, idx::Int)
    p.idx = idx; p.pane.offset = 0
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

scope!(:wiki, "Wiki (pane)")
bind!(:wiki, ["j", "↓"], "défiler"; group = :nav, repeat = true,
      action = p -> _scroll!(p.pane, :down))
bind!(:wiki, ["k", "↑"], "remonter"; group = :nav, repeat = true, when = p -> p.pane.offset > 0,
      action = p -> _scroll!(p.pane, :up))
bind!(:wiki, ["n", "]", "→"], "page du wiki suivante"; group = :nav,
      action = p -> (isempty(p.pages) || _wiki_show!(p, mod1(p.idx + 1, length(p.pages)))))
bind!(:wiki, ["p", "[", "←"], "page du wiki précédente"; group = :nav,
      action = p -> (isempty(p.pages) || _wiki_show!(p, mod1(p.idx - 1, length(p.pages)))))
bind!(:wiki, ["d", "PgDn"], "défiler d'un écran"; group = :nav, hint = false, repeat = true,
      action = p -> _scroll!(p.pane, :pagedown))
bind!(:wiki, ["u", "PgUp"], "remonter d'un écran"; group = :nav, hint = false, repeat = true,
      action = p -> _scroll!(p.pane, :pageup))
bind!(:wiki, ["g", "G"], "début / fin de page"; group = :nav, hint = false,
      action = (p, evt) -> _scroll!(p.pane, evt.char == 'g' ? :home : :end_key))
bind!(:wiki, ["1", "2", "3", "4", "5", "6", "7", "8", "9"], "aller à la page N"; group = :nav, hint = false,
      action = (p, evt) -> (n = Int(evt.char - '0');
                            1 <= n <= length(p.pages) && _wiki_show!(p, n)))
