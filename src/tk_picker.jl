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
    if evt.key === :char
        (evt.char != '\0' && _is_typable_ascii(evt.char)) || return false
        return TK.handle_key!(pk.input, evt)
    end
    evt.key in (:backspace, :delete, :left, :right) || return false
    return TK.handle_key!(pk.input, evt)
end

"""
    _picker_render_input!(pk, rect, buf; right_text = "", hint = "")

La ligne de saisie : le TextInput (curseur visible en mode recherche),
`right_text` à droite (un compte, un état). Hors recherche et sans
saisie, `hint` en grisé à la place (« / pour chercher · … »).
"""
function _picker_render_input!(pk::Picker, rect::TK.Rect, buf::TK.Buffer;
                               right_text::AbstractString = "", hint::AbstractString = "")
    (rect.height < 1 || rect.width < 4) && return
    rw = textwidth(right_text)
    w = max(1, rect.width - rw - (rw > 0 ? 1 : 0))
    if !pk.searching && isempty(_picker_query(pk)) && !isempty(hint)
        TK.set_string!(buf, rect.x, rect.y, first(rpad(hint, w), w), TK.tstyle(:text_dim))
    else
        pk.input.focused = pk.searching
        TK.render(pk.input, TK.Rect(rect.x, rect.y, w, 1), buf)
    end
    rw > 0 && TK.set_string!(buf, rect.x + rect.width - rw, rect.y, right_text, TK.tstyle(:text_dim))
    return
end

# La liste dans `rect` (marqueur, surbrillance, barre).
_picker_render_list!(pk::Picker, rect::TK.Rect, buf::TK.Buffer) =
    ((rect.height < 1 || rect.width < 3) || TK.render(pk.list, rect, buf); nothing)

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

# Un clic sur la ligne déjà sélectionnée ? (pour « clic = choisir »)
_picker_click_hits_selected(pk::Picker, evt::TK.MouseEvent) =
    evt.button === TK.mouse_left && evt.action === TK.mouse_press &&
    pk.list.offset + (evt.y - pk.list.last_area.y + 1) == pk.list.selected &&
    Base.contains(pk.list.last_area, evt.x, evt.y)
