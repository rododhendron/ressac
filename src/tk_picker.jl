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
end

function _picker()
    input = TK.TextInput(; label = "⌕ ", style = TK.tstyle(:accent, bold = true),
                         label_style = TK.tstyle(:accent, bold = true), focused = true)
    list = TK.SelectableList(TK.ListItem[]; focused = true, show_scrollbar = true)
    return Picker(input, list, Any[], "")
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

La saisie : un caractère imprimable filtre, retour arrière efface, ←/→
et Suppr déplacent ou coupent. Vrai si la touche a servi.
"""
function _picker_type!(pk::Picker, evt::TK.KeyEvent)
    if evt.key === :char
        (evt.char != '\0' && _is_typable_ascii(evt.char)) || return false
        return TK.handle_key!(pk.input, evt)
    end
    evt.key in (:backspace, :delete, :left, :right) || return false
    return TK.handle_key!(pk.input, evt)
end

"""
    _picker_render!(pk, inner, buf; right_text = "")

La saisie sur la première ligne (avec `right_text` à droite : un compte,
un état), la liste dessous.
"""
function _picker_render!(pk::Picker, inner::TK.Rect, buf::TK.Buffer; right_text::AbstractString = "")
    (inner.height < 1 || inner.width < 4) && return
    rw = textwidth(right_text)
    TK.render(pk.input, TK.Rect(inner.x, inner.y, max(1, inner.width - rw - 1), 1), buf)
    isempty(right_text) || TK.set_string!(buf, inner.x + inner.width - rw, inner.y, right_text, TK.tstyle(:text_dim))
    inner.height >= 2 && TK.render(pk.list, TK.Rect(inner.x, inner.y + 1, inner.width, inner.height - 1), buf)
    return
end

# Souris : un clic sélectionne la ligne, la molette fait défiler la liste.
_picker_mouse!(pk::Picker, evt::TK.MouseEvent) = TK.handle_mouse!(pk.list, evt)

# Un clic sur la ligne déjà sélectionnée ? (pour « clic = choisir »)
_picker_click_hits_selected(pk::Picker, evt::TK.MouseEvent) =
    evt.button === TK.mouse_left && evt.action === TK.mouse_press &&
    pk.list.offset + (evt.y - pk.list.last_area.y + 1) == pk.list.selected &&
    Base.contains(pk.list.last_area, evt.x, evt.y)
