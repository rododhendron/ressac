# src/tk_picker.jl
# Le « picker » : une saisie de filtre au-dessus d'une liste — le gabarit
# de la palette et des modales à choix (sons, patterns, recettes,
# extraits…). Tout vient de Tachikoma : `TextInput` pour la saisie
# (curseur, retour arrière, ←/→), `SelectableList` pour la liste
# (sélection, défilement, barre, clic, molette). Les touches restent
# déclarées dans le registre `bind!` de chaque modale et délèguent ici.

mutable struct Picker
    input::TK.TextInput
    list::TK.SelectableList
    keys::Vector{Any}            # ce que chaque ligne désigne, dans l'ordre de la liste
    last_query::String           # la saisie au dernier `_picker_set!` : si elle change, on remonte en tête
    searching::Bool              # la frappe va dans la saisie (sinon aux touches de la modale)
end

"""
    _picker(; searching = false) -> Picker

`searching = true` pour une modale qui est d'abord une barre de recherche
(la palette) ; les autres y entrent par `/` et en sortent par Entrée ou Échap.
"""
function _picker(; searching::Bool = false)
    input = TK.TextInput(; label = "⌕ ", style = TK.tstyle(:accent, bold = true),
                         label_style = TK.tstyle(:accent, bold = true), focused = searching)
    list = TK.SelectableList(TK.ListItem[]; focused = true, show_scrollbar = true)
    return Picker(input, list, Any[], "", searching)
end

"""
    _search_input() -> Tachikoma.TextInput

Une saisie de recherche seule, pour une modale dont la liste n'est pas
une colonne (la grille de sons). `focused` dit si la frappe y va.
"""
_search_input() = TK.TextInput(; label = "⌕ ", style = TK.tstyle(:accent, bold = true),
                               label_style = TK.tstyle(:accent, bold = true), focused = false)

# La frappe dans une saisie seule, si elle est active : mêmes règles que
# `_picker_type!`.
function _search_type!(input::TK.TextInput, evt::TK.KeyEvent)
    input.focused || return false
    if evt.key === :char
        _is_typable(evt.char) || return false
        return TK.handle_key!(input, evt)
    end
    evt.key in (:backspace, :delete, :left, :right) || return false
    return TK.handle_key!(input, evt)
end

# La ligne de saisie seule : le TextInput (curseur si active), `right_text`
# à droite, `hint` en grisé quand elle est inactive et vide.
function _search_render!(input::TK.TextInput, rect::TK.Rect, buf::TK.Buffer;
                         right_text::AbstractString = "", hint::AbstractString = "")
    (rect.height < 1 || rect.width < 4) && return
    rw = textwidth(right_text)
    w = max(1, rect.width - rw - (rw > 0 ? 1 : 0))
    # Le champ : une ligne sur le fond des lignes choisies, sans cadre.
    _clear_rect!(buf, rect)
    for x in rect.x:(rect.x + rect.width - 1)
        _tint_cell!(buf, x, rect.y, _ui().s3)
    end
    if !input.focused && isempty(TK.text(input)) && !isempty(hint)
        TK.set_string!(buf, rect.x, rect.y, first(rpad(hint, w), w), TK.tstyle(:text_dim))
    else
        TK.render(input, TK.Rect(rect.x, rect.y, w, 1), buf)
    end
    rw > 0 && TK.set_string!(buf, rect.x + rect.width - rw, rect.y, right_text, TK.tstyle(:text_dim))
    return
end

# Entre ou sort du mode recherche.
_picker_search!(pk::Picker, on::Bool) = (pk.searching = on; pk.input.focused = on; nothing)

# Efface la saisie et remonte en tête, sans toucher au mode.
function _picker_clear!(pk::Picker)
    TK.set_text!(pk.input, "")
    pk.last_query = ""
    pk.list.selected = 1; pk.list.offset = 0
    return
end

_picker_query(pk::Picker) = TK.text(pk.input)

# Vide la saisie et remonte en tête (à l'ouverture d'une modale).
function _picker_reset!(pk::Picker)
    TK.set_text!(pk.input, "")
    pk.last_query = ""
    pk.list.items = TK.ListItem[]; pk.keys = Any[]
    pk.list.selected = 1; pk.list.offset = 0
    return
end

"""
    _picker_set!(pk, items, keys)

Pose les lignes visibles (déjà filtrées et formatées) et ce qu'elles
désignent. Une saisie qui a changé remet la sélection en tête ; sinon
elle est simplement bornée.
"""
function _picker_set!(pk::Picker, items::Vector{TK.ListItem}, keys::AbstractVector)
    pk.list.items = items
    pk.keys = collect(Any, keys)
    q = _picker_query(pk)
    if q != pk.last_query
        pk.list.selected = 1; pk.list.offset = 0
        pk.last_query = q
    end
    pk.list.selected = clamp(pk.list.selected, 1, max(1, length(items)))
    return
end

# Ce que désigne la ligne sélectionnée, ou `nothing`.
_picker_selected(pk::Picker) =
    (i = pk.list.selected; 1 <= i <= length(pk.keys) ? pk.keys[i] : nothing)

# Navigation dans la liste comme une touche Tachikoma (:up, :down,
# :pageup, :pagedown, :home, :end_key). ↓ au bout revient en tête.
_picker_nav!(pk::Picker, key::Symbol) = TK.handle_key!(pk.list, TK.KeyEvent(key))

"""
    _picker_type!(pk, evt) -> Bool

La saisie, en mode recherche seulement : un caractère imprimable filtre,
retour arrière efface, ←/→ et Suppr déplacent ou coupent. Vrai si la
touche a servi.
"""
function _picker_type!(pk::Picker, evt::TK.KeyEvent)
    pk.searching || return false
    pk.input.focused = true
    return _search_type!(pk.input, evt)
end

"""
    _picker_render_input!(pk, rect, buf; right_text = "", hint = "")

La ligne de saisie : le TextInput (curseur visible en mode recherche),
`right_text` à droite (un compte, un état). Hors recherche et sans
saisie, `hint` en grisé à la place (« / pour chercher · … »).
"""
function _picker_render_input!(pk::Picker, rect::TK.Rect, buf::TK.Buffer;
                               right_text::AbstractString = "", hint::AbstractString = "")
    pk.input.focused = pk.searching
    _search_render!(pk.input, rect, buf; right_text, hint)
end

# La liste dans `rect` (marqueur, surbrillance, barre).
function _picker_render_list!(pk::Picker, rect::TK.Rect, buf::TK.Buffer)
    (rect.height < 1 || rect.width < 3) && return
    TK.render(pk.list, rect, buf)
    _selected_row_tint!(buf, rect, pk.list.selected - pk.list.offset)
    return
end

# La ligne choisie d'une liste : le fond des lignes choisies, sur toute sa largeur.
function _selected_row_tint!(buf::TK.Buffer, rect::TK.Rect, row::Int)
    (1 <= row <= rect.height) || return
    y = rect.y + row - 1
    for x in rect.x:(rect.x + rect.width - 1)
        _tint_cell!(buf, x, y, _ui().s3)
    end
    return
end

"""
    _datatable_render!(dt, rect, buf)

Une table sans filets : l'en-tête en discret, les colonnes séparées par
leur alignement, la ligne choisie sur son fond. (Le widget de Tachikoma
trace des `│` et un `─` sous l'en-tête : on les efface après coup.)
"""
function _datatable_render!(dt::TK.DataTable, rect::TK.Rect, buf::TK.Buffer)
    TK.render(dt, rect, buf)
    for y in rect.y:(rect.y + rect.height - 1), x in rect.x:(rect.x + rect.width - 1)
        TK.in_bounds(buf, x, y) || continue
        i = TK.buf_index(buf, x, y)
        buf.content[i].char in ('│', '─', '┼', '┬', '┴', '├', '┤') && (buf.content[i] = TK.Cell(' ', TK.Style(), ""))
    end
    xy = dt.selected >= 1 ? _datatable_cell_xy(dt, dt.selected, 1) : nothing
    xy === nothing || _selected_row_tint!(buf, rect, xy[2] - rect.y + 1)
    return
end

"""
    _picker_render!(pk, inner, buf; right_text = "", hint = "")

La saisie sur la première ligne, la liste dessous.
"""
function _picker_render!(pk::Picker, inner::TK.Rect, buf::TK.Buffer;
                         right_text::AbstractString = "", hint::AbstractString = "")
    (inner.height < 1 || inner.width < 4) && return
    _picker_render_input!(pk, TK.Rect(inner.x, inner.y, inner.width, 1), buf; right_text, hint)
    inner.height >= 2 && _picker_render_list!(pk, TK.Rect(inner.x, inner.y + 1, inner.width, inner.height - 1), buf)
    return
end

# Souris : un clic sélectionne la ligne, la molette fait défiler la liste.
_picker_mouse!(pk::Picker, evt::TK.MouseEvent) = TK.handle_mouse!(pk.list, evt)

# ── Listes : ce qui vaut pour une SelectableList comme pour une DataTable ──

# Un clic gauche sur la ligne déjà sélectionnée ? (pour « clic = choisir »)
function _list_click_hits_selected(lst::TK.SelectableList, evt::TK.MouseEvent)
    evt.button === TK.mouse_left && evt.action === TK.mouse_press || return false
    Base.contains(lst.last_area, evt.x, evt.y) || return false
    return lst.offset + (evt.y - lst.last_area.y + 1) == lst.selected
end
function _list_click_hits_selected(dt::TK.DataTable, evt::TK.MouseEvent)
    evt.button === TK.mouse_left && evt.action === TK.mouse_press || return false
    a = dt.last_content_area
    Base.contains(a, evt.x, evt.y) || return false
    return dt.offset + (evt.y - (a.y + 2) + 1) == dt.selected      # en-tête + filet
end
_picker_click_hits_selected(pk::Picker, evt::TK.MouseEvent) = _list_click_hits_selected(pk.list, evt)

# Navigation au clavier comme la touche Tachikoma correspondante.
_list_nav!(lst, key::Symbol) = (TK.handle_key!(lst, TK.KeyEvent(key)); nothing)

"""
    _mixer_table() -> Tachikoma.DataTable

La table du mixer : une ligne par slot, colonnes remplies à chaque rendu.
"""
_mixer_table() = TK.DataTable(TK.DataColumn[]; selected = 1, show_scrollbar = true,
                              header_style = TK.tstyle(:text_dim), selected_style = TK.tstyle(:accent, bold = true),
                              alt_style = TK.tstyle(:text))

"""
    _datatable_set!(dt, columns, row_styles)

Remplace les colonnes d'une DataTable en gardant sélection, défilement
et largeurs ; la sélection est bornée sur les nouvelles lignes.
"""
function _datatable_set!(dt::TK.DataTable, columns::Vector{TK.DataColumn}, row_styles::Vector{TK.Style} = TK.Style[])
    n = isempty(columns) ? 0 : maximum(length(c.values) for c in columns)
    dt.columns = columns
    dt.sort_perm = collect(1:n)
    dt.row_styles = row_styles
    dt.selected = n == 0 ? 0 : clamp(max(dt.selected, 1), 1, n)
    length(dt.col_widths) == length(columns) || (dt.col_widths = zeros(Int, length(columns)))
    return
end

# Position (x, y) de la cellule (ligne `row`, colonne `col`) au dernier rendu,
# ou `nothing` si elle n'est pas à l'écran — pour dessiner par-dessus.
function _datatable_cell_xy(dt::TK.DataTable, row::Int, col::Int)
    a = dt.last_content_area
    (a.width == 0 || length(dt.last_widths) < col) && return nothing
    y = a.y + 2 + (row - 1 - dt.offset)
    (y < a.y + 2 || y >= a.y + a.height) && return nothing
    x = a.x + 1 + sum(dt.last_widths[1:col-1]; init = 0) + (col - 1)     # marge + séparateurs
    return (x, y)
end

# ── Deux formes partagées ─────────────────────────────────────────────

"""
    _render_tabs!(buf, rect, labels, active)

Une rangée d'onglets (les catégories d'une modale) : l'onglet actif en
orange souligné, les autres en secondaire.
"""
function _render_tabs!(buf::TK.Buffer, rect::TK.Rect, labels::Vector{String}, active::Int)
    (rect.width < 4 || rect.height < 1 || isempty(labels)) && return
    p = _ui()
    act = clamp(active, 1, length(labels))
    x = rect.x
    for (i, l) in enumerate(labels)
        i > 1 && (x + 3 <= rect.x + rect.width && TK.set_string!(buf, x, rect.y, " · ", TK.Style(fg = p.x)); x += 3)
        x + textwidth(l) > rect.x + rect.width && break
        TK.set_string!(buf, x, rect.y, l, i == act ? TK.Style(fg = p.o, bold = true, underline = true) : TK.Style(fg = p.d))
        x += textwidth(l)
    end
    return
end

"""
    _render_candidate_grid!(buf, area, candidates, selected; min_cell = 14) -> cols

La grille des candidats d'une complétion, en colonnes : `▶` devant le
candidat choisi, la ligne qui le porte toujours visible. Tachikoma n'a pas
de liste à plusieurs colonnes ; celle-ci sert à la fois à la complétion de
l'éditeur et à celle de la barre de commande. Rend le nombre de colonnes
(les flèches ↑ / ↓ s'en servent pour sauter d'une ligne).
"""
function _render_candidate_grid!(buf::TK.Buffer, area::TK.Rect, candidates::Vector{String}, selected::Int;
                                 min_cell::Int = 14)
    n = length(candidates)
    (n == 0 || area.height < 1 || area.width < 4) && return 1
    # La zone est effacée d'abord : une liste qui raccourcit ne laisse pas
    # voir la frame d'avant (ni le journal, quand la grille le recouvre).
    blank = repeat(' ', area.width)
    for y in area.y:(area.y + area.height - 1)
        TK.set_string!(buf, area.x, y, blank, TK.tstyle(:text))
    end
    cell_w = max(maximum(textwidth, candidates) + 4, min_cell)   # « ▶ » + libellé + gouttière
    cols = clamp(area.width ÷ cell_w, 1, n)
    rows = cld(n, cols)
    sel_row = cld(max(selected, 1), cols)
    first_row = _scroll_to_show(sel_row, rows, area.height, 0) + 1
    for r in first_row:min(rows, first_row + area.height - 1), c in 1:cols
        i = (r - 1) * cols + c
        i > n && break
        cur = i == selected
        text = first(rpad((cur ? "▶ " : "  ") * candidates[i], cell_w - 1), cell_w - 1)
        TK.set_string!(buf, area.x + (c - 1) * cell_w, area.y + (r - first_row), text,
                       cur ? TK.tstyle(:accent, bold = true) : TK.tstyle(:text))
    end
    return cols
end
