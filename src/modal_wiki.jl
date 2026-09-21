# Wiki — in-app documentation browser modal.
# Pages live in docs/wiki/*.md and are loaded by `_load_wiki_pages`
# (defined in src/content_wiki.jl), one `_WikiPage` per file. Re-opens always
# re-read from disk so editing a .md while Ressac is running shows up
# on the next :wiki.
#
# Extracted from app.jl as part of the maintainability sprint.

"""
    _open_wiki!(m)

Open the wiki modal, reloading pages from `docs/wiki/*.md` so any
edits since the last open take effect immediately.
"""
function _open_wiki!(m::RessacApp)
    m.wiki_pages = _load_wiki_pages()
    if isempty(m.wiki_pages)
        _push_app_log!(m, "[WARN] :wiki — aucune page dans docs/wiki/")
        return
    end
    m.modal = :wiki
    m.wiki_idx = clamp(m.wiki_idx, 1, length(m.wiki_pages))
    m.wiki_scroll = 0
end

function _handle_wiki_key!(m::RessacApp, evt::TK.KeyEvent)
    isempty(m.wiki_pages) && (m.modal = :none; return)
    dispatch!(((:modal_wiki, m),), evt)
    return
end

"""
    _render_wiki_modal!(m, area, buf)

Two-column layout: TOC on the left (~28 cols), content on the
right. Title row + footer hint frame the modal.
"""
function _render_wiki_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    isempty(m.wiki_pages) && return
    page = m.wiki_pages[m.wiki_idx]
    inner = _render_modal_block!(buf, area;
        title = "WIKI · $(page.title)",
        title_right = _modal_hint_text(m, :modal_wiki),
        w_max = max(80, area.width - 4),
        h_target = max(20, area.height - 4))
    inner.width < 30 && return
    # Two-column split inside the bordered area: TOC (left) + content (right).
    toc_w = max(20, inner.width ÷ 4)
    # ── TOC ─────────────────────────────────────────────────────────
    for (i, p) in enumerate(m.wiki_pages)
        i > inner.height && break
        is_cur = i == m.wiki_idx
        prefix = is_cur ? "▶ " : "  "
        label = "$(prefix)$(i). $(p.title)"
        style = is_cur ? TK.tstyle(:accent, bold = true) : TK.tstyle(:text)
        TK.set_string!(buf, inner.x + 1, inner.y + i - 1,
                       first(rpad(label, toc_w - 2), toc_w - 2),
                       style)
    end
    # Vertical separator between TOC and content.
    sep_x = inner.x + toc_w
    for y in inner.y:(inner.y + inner.height - 1)
        TK.set_string!(buf, sep_x, y, "│", TK.tstyle(:border))
    end
    # ── Content ─────────────────────────────────────────────────────
    content_x = sep_x + 2
    content_w = inner.width - toc_w - 2
    visible = page.lines[max(1, m.wiki_scroll + 1):end]
    in_code = false
    for (i, line) in enumerate(visible)
        i > inner.height && break
        if startswith(strip(line), "```")
            in_code = !in_code
            TK.set_string!(buf, content_x, inner.y + i - 1,
                           first(rpad("┄" * "─" ^ (content_w - 1), content_w), content_w),
                           TK.tstyle(:border))
            continue
        end
        _render_markdown_line!(line, buf, content_x, inner.y + i - 1,
                               content_w; in_code = in_code)
    end
end

# ── Registre de touches (déclaré en fin de fichier : les actions nommées
#    doivent exister au moment du bind!) ──
_wiki_last(m::RessacApp) = max(0, length(m.wiki_pages[m.wiki_idx].lines) - 1)
scope!(:modal_wiki, "Wiki")
bind!(:modal_wiki, ["j", "↓"], "défiler"; group = :nav, hint = false,
      action = m -> (m.wiki_scroll = min(m.wiki_scroll + 1, _wiki_last(m))))
bind!(:modal_wiki, ["k", "↑"], "remonter"; group = :nav, hint = false,
      action = m -> (m.wiki_scroll = max(0, m.wiki_scroll - 1)))
bind!(:modal_wiki, ["n", "]", "→"], "page suivante"; group = :nav,
      action = m -> (m.wiki_idx = mod1(m.wiki_idx + 1, length(m.wiki_pages)); m.wiki_scroll = 0))
bind!(:modal_wiki, ["p", "[", "←"], "page précédente"; group = :nav,
      action = m -> (m.wiki_idx = mod1(m.wiki_idx - 1, length(m.wiki_pages)); m.wiki_scroll = 0))
bind!(:modal_wiki, "d", "10 lignes plus bas"; group = :nav, hint = false,
      action = m -> (m.wiki_scroll = min(m.wiki_scroll + 10, _wiki_last(m))))
bind!(:modal_wiki, "u", "10 lignes plus haut"; group = :nav, hint = false,
      action = m -> (m.wiki_scroll = max(0, m.wiki_scroll - 10)))
bind!(:modal_wiki, ["g", "G"], "début / fin de page"; group = :nav, hint = false,
      action = (m, evt) -> (m.wiki_scroll = evt.char == 'g' ? 0 : _wiki_last(m)))
bind!(:modal_wiki, ["1", "2", "3", "4", "5", "6", "7", "8", "9"], "aller à la page N"; group = :nav, hint = false,
      action = (m, evt) -> (n = Int(evt.char - '0');
                            1 <= n <= length(m.wiki_pages) && (m.wiki_idx = n; m.wiki_scroll = 0)))
bind!(:modal_wiki, ["Esc", "q"], "fermer"; group = :nav, action = m -> (m.modal = :none))
