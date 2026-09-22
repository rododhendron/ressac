# src/modal_palette.jl
# Palette — un seul endroit pour retrouver n'importe quoi : une commande,
# un son, une fonction, un pattern rangé, une recette de synth, une page
# du wiki. On tape, on filtre, Entrée fait ce qu'il faut selon la nature
# de l'entrée. Ctrl-p depuis n'importe où.

"""
    _PaletteItem(kind, label, detail, action)

Une entrée de la palette : sa nature (pour l'icône et le tri), ce qui
s'affiche, un complément à droite, et ce que fait Entrée.
"""
struct _PaletteItem
    kind::Symbol       # :cmd | :sound | :func | :pattern | :recipe | :wiki
    label::String
    detail::String
    action::Function
end

const _PALETTE_ICON = Dict{Symbol,String}(
    :cmd => ":", :sound => "♪", :func => "ƒ", :pattern => "▣", :recipe => "◈", :wiki => "?",
)
const _PALETTE_LABEL = Dict{Symbol,String}(
    :cmd => "commande", :sound => "son", :func => "fonction",
    :pattern => "pattern rangé", :recipe => "recette", :wiki => "wiki",
)

function _open_palette!(m::RessacApp)
    _open_modal!(m, :palette, :palette_cursor)
    m.palette_query = ""
end

"""
    _palette_items(m) -> Vector{_PaletteItem}

Tout ce que la palette sait atteindre, filtré par la saisie. L'ordre
suit la pertinence : correspondance exacte d'abord, puis par nature.
"""
function _palette_items(m::RessacApp)
    out = _PaletteItem[]
    # Toutes les commandes réellement enregistrées, pas une liste tenue à
    # la main : la palette ne peut pas dériver du registre.
    for name in _all_ex_verbs()
        push!(out, _PaletteItem(:cmd, ":" * name, "", mm -> _handle_ex_command!(mm, name)))
    end
    for (reg, what) in ((_SAMPLE_REGISTRY, "sample"), (_INSTRUMENT_REGISTRY, "instrument"),
                        (_SYNTH_REGISTRY, "synth"))
        for k in keys(reg)
            nm = String(k)
            push!(out, _PaletteItem(:sound, nm, what, mm -> _palette_insert!(mm, nm)))
        end
    end
    for name in _COMBINATOR_NAMES
        e = lookup_doc(name)
        push!(out, _PaletteItem(:func, name, e === nothing ? "" : first(e.short, 60),
                                mm -> (_palette_insert!(mm, name); _show_doc_pane!(mm, name))))
    end
    for e in list_patterns()
        push!(out, _PaletteItem(:pattern, e.name, isempty(e.tags) ? "" : join(e.tags, ", "),
                                mm -> _load_pattern_cmd!(mm, e.name)))
    end
    for e in _synthlib_all_entries()
        e.category == "user" && continue
        synth_info(Symbol(e.name)) === nothing || continue      # déjà installé
        push!(out, _PaletteItem(:recipe, e.name, "à installer",
                                mm -> _add_synth_from_library!(mm, e.name)))
    end
    for (i, pg) in enumerate(_load_wiki_pages())
        push!(out, _PaletteItem(:wiki, pg.title, "page $i",
                                mm -> _open_wiki!(mm; page = string(i))))
    end
    q = m.palette_query
    isempty(q) || (out = [it for it in out if _fuzzy_score(q, it.label) !== nothing])
    # `_fuzzy_score` : plus bas = plus serré. À score égal, le plus court
    # d'abord — taper « rev » doit proposer rev avant reverse-machin.
    sort!(out; by = it -> (something(_fuzzy_score(q, it.label), 10^6),
                           length(it.label), it.label))
    return out
end

_palette_cur(m::RessacApp) =
    (it = _palette_items(m); 1 <= m.palette_cursor <= length(it) ? it[m.palette_cursor] : nothing)

# Insère un nom au curseur de l'éditeur actif.
function _palette_insert!(m::RessacApp, name::AbstractString)
    ed = _active_editor(m)
    ed === nothing && return
    1 <= ed.cursor_row <= length(ed.lines) || return
    line = String(ed.lines[ed.cursor_row])
    col = clamp(ed.cursor_col, 0, length(line))
    lines = collect(String, split(TK.text(ed), '\n'; keepempty = true))
    lines[ed.cursor_row] = _take_chars(line, col) * name * _drop_chars(line, col)
    row = ed.cursor_row
    TK.set_text!(ed, join(lines, '\n'))
    ed.cursor_row = row
    ed.cursor_col = col + length(name)
    _push_app_log!(m, "[INFO] « $name » inséré")
end

function _palette_run!(m::RessacApp)
    it = _palette_cur(m)
    it === nothing && return
    m.modal = :none
    it.action(m)
end

function _handle_palette_key!(m::RessacApp, evt::TK.KeyEvent)
    if evt.key === :escape
        m.modal = :none
        return
    elseif evt.key === :backspace
        isempty(m.palette_query) ||
            (m.palette_query = m.palette_query[1:prevind(m.palette_query, end)])
        m.palette_cursor = 1
        return
    end
    dispatch!(((:modal_palette, m),), evt) && return
    # Tout caractère imprimable filtre : la palette est d'abord une barre
    # de recherche, la navigation passe par les flèches et Ctrl-n / Ctrl-p.
    if evt.key === :char && evt.char != '\0' && _is_typable_ascii(evt.char)
        m.palette_query *= string(evt.char)
        m.palette_cursor = 1
    end
    return
end

function _render_palette_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    items = _palette_items(m)
    n = length(items)
    inner = _render_modal_block!(buf, area;
        title = "PALETTE",
        title_right = _modal_hint_text(m, :modal_palette),
        w_max = 110,
        h_target = max(14, min(area.height - 4, n + 6)))
    inner.width < 24 && return
    count_txt = "$n"
    q = "⌕ " * m.palette_query * "▏"
    w = max(0, inner.width - textwidth(count_txt))
    TK.set_string!(buf, inner.x, inner.y, first(rpad(q, w), w), TK.tstyle(:accent, bold = true))
    TK.set_string!(buf, inner.x + inner.width - textwidth(count_txt), inner.y,
                   count_txt, TK.tstyle(:text_dim))
    body_y = inner.y + 1
    body_h = inner.height - 1
    m.modal_scroll = _scroll_to_show(m.palette_cursor, n, body_h, m.modal_scroll)
    for i in 1:body_h
        idx = m.modal_scroll + i
        idx > n && break
        it = items[idx]
        sel = idx == m.palette_cursor
        icon = get(_PALETTE_ICON, it.kind, "·")
        left = "$(sel ? "▶" : " ") $icon $(it.label)"
        detail = isempty(it.detail) ? get(_PALETTE_LABEL, it.kind, "") : it.detail
        line = rpad(first(left, max(1, inner.width - 24)), max(1, inner.width - 24)) *
               first(detail, 23)
        TK.set_string!(buf, inner.x, body_y + i - 1,
                       first(rpad(line, inner.width), inner.width),
                       sel ? TK.tstyle(:accent, bold = true) : TK.tstyle(:text))
    end
end

# ── Registre de touches ────────────────────────────────────────────
scope!(:modal_palette, "Palette (Ctrl-p)")
bind!(:modal_palette, "Enter", "ouvrir / insérer / lancer"; short = "valider", group = :edit,
      action = m -> _palette_run!(m))
bind!(:modal_palette, ["↓", "Ctrl-n"], "suivant"; group = :nav, hint = false, repeat = true,
      action = m -> (m.palette_cursor = min(m.palette_cursor + 1, max(1, length(_palette_items(m))))))
bind!(:modal_palette, ["↑", "Ctrl-p"], "précédent"; group = :nav, hint = false, repeat = true,
      action = m -> (m.palette_cursor = max(1, m.palette_cursor - 1)))
bind!(:modal_palette, ["PgDn"], "page suivante"; group = :nav, hint = false, repeat = true,
      action = m -> (m.palette_cursor = min(m.palette_cursor + 15, max(1, length(_palette_items(m))))))
bind!(:modal_palette, ["PgUp"], "page précédente"; group = :nav, hint = false, repeat = true,
      action = m -> (m.palette_cursor = max(1, m.palette_cursor - 15)))
bind!(:modal_palette, "Esc", "fermer"; group = :nav, action = m -> (m.modal = :none))
bind!(:modal_palette, "a-z", "filtrer en tapant"; group = :edit, hint = false)
