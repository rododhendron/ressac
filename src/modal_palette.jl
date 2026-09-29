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
    _open_modal!(m, :palette)
    _picker_reset!(m.palette)
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
    q = _picker_query(m.palette)
    isempty(q) || (out = [it for it in out if _fuzzy_score(q, it.label) !== nothing])
    # `_fuzzy_score` : plus bas = plus serré. À score égal, le plus court
    # d'abord — taper « rev » doit proposer rev avant reverse-machin.
    sort!(out; by = it -> (something(_fuzzy_score(q, it.label), 10^6),
                           length(it.label), it.label))
    return out
end

"""
    _palette_sync!(m, width = 80) -> Vector{_PaletteItem}

Recalcule les entrées filtrées et les pose dans le picker, formatées
pour `width` colonnes : icône, libellé, complément à droite.
"""
function _palette_sync!(m::RessacApp, width::Int = 80)
    items = _palette_items(m)
    lw = max(1, width - 26)
    rows = [TK.ListItem(rpad(first("$(get(_PALETTE_ICON, it.kind, "·")) $(it.label)", lw), lw) *
                        first(isempty(it.detail) ? get(_PALETTE_LABEL, it.kind, "") : it.detail, 23),
                        it.kind === :cmd ? TK.tstyle(:text) : TK.tstyle(:text))
            for it in items]
    _picker_set!(m.palette, rows, items)
    return items
end

_palette_cur(m::RessacApp) = (_palette_sync!(m); _picker_selected(m.palette))

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
    end
    dispatch!(((:modal_palette, m),), evt) && return
    # Tout caractère imprimable filtre : la palette est d'abord une barre
    # de recherche, la navigation passe par les flèches et Ctrl-n / Ctrl-p.
    _picker_type!(m.palette, evt)
    return
end

# Souris dans la palette : un clic sélectionne, un second sur la même
# ligne valide, la molette fait défiler.
function _palette_mouse!(m::RessacApp, evt::TK.MouseEvent)
    if _picker_click_hits_selected(m.palette, evt)
        _palette_run!(m)
        return true
    end
    return _picker_mouse!(m.palette, evt)
end

function _render_palette_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    n = length(_palette_items(m))
    inner = _render_modal_block!(buf, area;
        title = "PALETTE",
        title_right = _modal_hint_text(m, :modal_palette),
        w_max = 110,
        h_target = max(14, min(area.height - 4, n + 6)))
    inner.width < 24 && return
    _palette_sync!(m, inner.width - 3)            # marqueur, barre
    _picker_render!(m.palette, inner, buf; right_text = "$n")
end

scope!(:modal_palette, "Palette (Ctrl-p)")
bind!(:modal_palette, "Enter", "ouvrir / insérer / lancer"; short = "valider", group = :edit,
      action = m -> _palette_run!(m))
bind!(:modal_palette, ["↓", "Ctrl-n"], "suivant"; group = :nav, hint = false, repeat = true,
      action = m -> (_palette_sync!(m); _picker_nav!(m.palette, :down)))
bind!(:modal_palette, ["↑", "Ctrl-p"], "précédent"; group = :nav, hint = false, repeat = true,
      action = m -> (_palette_sync!(m); _picker_nav!(m.palette, :up)))
bind!(:modal_palette, ["PgDn"], "page suivante"; group = :nav, hint = false, repeat = true,
      action = m -> (_palette_sync!(m); _picker_nav!(m.palette, :pagedown)))
bind!(:modal_palette, ["PgUp"], "page précédente"; group = :nav, hint = false, repeat = true,
      action = m -> (_palette_sync!(m); _picker_nav!(m.palette, :pageup)))
bind!(:modal_palette, "Esc", "fermer"; group = :nav, action = m -> (m.modal = :none))
bind!(:modal_palette, "a-z", "filtrer en tapant"; group = :edit, hint = false)
