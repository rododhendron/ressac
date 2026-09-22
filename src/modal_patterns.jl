# src/modal_patterns.jl
# Sélecteur de patterns rangés — ranger vite, retrouver vite, recharger
# sur le slot qu'on veut. Le pendant, côté rythme, de la librairie de
# synths : on essaie beaucoup, on garde ce qui marche.

function _open_patterns_modal!(m::RessacApp)
    _open_modal!(m, :patterns, :pat_cursor)
    m.pat_query = ""
    m.pat_search_mode = false
    if isempty(list_patterns())
        _push_app_log!(m, "[INFO] aucun pattern rangé — :keep <nom> range le bloc sous le curseur")
    end
end

function _pattern_entries(m::RessacApp)
    out = list_patterns()
    isempty(m.pat_query) && return out
    q = lowercase(m.pat_query)
    return filter(e -> _fuzzy_score(m.pat_query, e.name) !== nothing ||
                       any(t -> occursin(q, lowercase(t)), e.tags), out)
end

_pattern_cur(m::RessacApp) =
    (e = _pattern_entries(m); 1 <= m.pat_cursor <= length(e) ? e[m.pat_cursor] : nothing)

function _handle_patterns_key!(m::RessacApp, evt::TK.KeyEvent)
    if m.pat_search_mode
        if evt.key === :escape
            m.pat_search_mode = false; m.pat_query = ""; m.pat_cursor = 1
            return
        elseif evt.key === :enter
            m.pat_search_mode = false
            return
        elseif evt.key === :backspace
            isempty(m.pat_query) || (m.pat_query = m.pat_query[1:prevind(m.pat_query, end)])
            m.pat_cursor = 1
            return
        elseif evt.key === :char && evt.char != '\0' && _is_typable_ascii(evt.char)
            m.pat_query *= string(evt.char); m.pat_cursor = 1
            return
        end
    end
    if evt.key === :escape || evt.char == 'q'
        if isempty(m.pat_query)
            m.modal = :none
        else
            m.pat_query = ""; m.pat_cursor = 1
        end
        return
    end
    dispatch!(((:modal_patterns, m),), evt) && return
    return
end

function _render_patterns_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    entries = _pattern_entries(m)
    n = length(entries)
    inner = _render_modal_block!(buf, area;
        title = "PATTERNS RANGÉS",
        title_right = _modal_hint_text(m, :modal_patterns),
        w_max = 110,
        h_target = max(14, min(area.height - 4, n + 8)))
    inner.width < 24 && return
    count_txt = "$(n) rangé$(n == 1 ? "" : "s")" * (n == 0 ? "" : "  ·  $(m.pat_cursor)/$n")
    sb = m.pat_search_mode ? "⌕ " * m.pat_query * "▏" :
         isempty(m.pat_query) ? "/ pour chercher · Entrée charge · 1-9 charge sur le slot" :
         "⌕ " * m.pat_query
    sb_style = m.pat_search_mode ? TK.tstyle(:accent, bold = true) :
               isempty(m.pat_query) ? TK.tstyle(:text_dim) : TK.tstyle(:text)
    w = max(0, inner.width - textwidth(count_txt))
    TK.set_string!(buf, inner.x, inner.y, first(rpad(sb, w), w), sb_style)
    TK.set_string!(buf, inner.x + inner.width - textwidth(count_txt), inner.y,
                   count_txt, TK.tstyle(:text_dim))
    if n == 0
        TK.set_string!(buf, inner.x, inner.y + 2,
                       first("Rien de rangé. « :keep <nom> » range le bloc @dN sous le curseur.", inner.width),
                       TK.tstyle(:text_dim))
        return
    end
    # Liste à gauche, code du pattern sélectionné à droite.
    list_w = max(18, min(30, inner.width ÷ 3))
    body_y = inner.y + 1
    body_h = inner.height - 1
    m.modal_scroll = _scroll_to_show(m.pat_cursor, n, body_h, m.modal_scroll)
    for i in 1:body_h
        idx = m.modal_scroll + i
        idx > n && break
        e = entries[idx]
        sel = idx == m.pat_cursor
        slot = pattern_slot(e.code)
        label = "$(sel ? "▶ " : "  ")$(e.name)" * (slot === nothing ? "" : "  d$slot")
        TK.set_string!(buf, inner.x, body_y + i - 1, first(rpad(label, list_w), list_w),
                       sel ? TK.tstyle(:accent, bold = true) : TK.tstyle(:text))
    end
    sep_x = inner.x + list_w
    for y in body_y:(body_y + body_h - 1)
        TK.set_string!(buf, sep_x, y, "│", TK.tstyle(:border))
    end
    cur = entries[clamp(m.pat_cursor, 1, n)]
    code_x = sep_x + 2
    code_w = inner.width - list_w - 2
    row = 0
    if !isempty(cur.tags)
        TK.set_string!(buf, code_x, body_y, first("[" * join(cur.tags, ", ") * "]", code_w),
                       TK.tstyle(:text_dim))
        row = 2
    end
    for line in split(cur.code, '\n')
        row >= body_h && break
        TK.set_string!(buf, code_x, body_y + row, first(String(line), code_w), TK.tstyle(:text_bright))
        row += 1
    end
end

# ── Actions ────────────────────────────────────────────────────────

"""
    _save_pattern_cmd!(m, arg)

`:keep <nom> [tags…]` — range le bloc `@dN` sous le curseur.
"""
function _save_pattern_cmd!(m::RessacApp, arg::AbstractString)
    parts = split(strip(arg))
    isempty(parts) && (_push_app_log!(m, "[WARN] :keep <nom> [étiquettes…] — range le bloc sous le curseur"); return false)
    name = String(parts[1]); tags = String.(parts[2:end])
    code = _block_under_cursor(m)
    if code === nothing || isempty(strip(code))
        _push_app_log!(m, "[WARN] :keep — pose le curseur sur un bloc @dN à ranger")
        return false
    end
    try
        e = save_pattern!(name, code; tags = tags)
        _push_app_log!(m, "[INFO] pattern « $(e.name) » rangé — :recall $(e.name) le rappelle, Espace P les liste")
        return true
    catch err
        _push_app_log!(m, "[ERROR] :keep — $(sprint(showerror, err))")
        return false
    end
end

# Le bloc logique sous le curseur (lignes `|>` comprises).
function _block_under_cursor(m::RessacApp)
    ed = _active_editor(m)
    ed === nothing && return nothing
    lines = collect(String, split(TK.text(ed), '\n'; keepempty = true))
    row = clamp(ed.cursor_row, 1, max(1, length(lines)))
    1 <= row <= length(lines) || return nothing
    (a, b) = _logical_block_range(lines, row)
    return _join_logical_block(lines[a:max(b, a)])
end

"""
    _load_pattern_cmd!(m, name, slot)

`:recall <nom> [slot]` — réinsère un pattern rangé dans le buffer et
l'évalue. Sans slot, celui d'origine ; s'il est déjà pris par un autre
bloc, le premier libre.
"""
function _load_pattern_cmd!(m::RessacApp, name::AbstractString, slot::Union{Nothing,Int} = nothing)
    e = load_pattern(name)
    if e === nothing
        _push_app_log!(m, "[WARN] :recall — pas de pattern « $name » (Espace P pour la liste)")
        return false
    end
    ed = _active_editor(m)
    ed === nothing && return false
    target = slot === nothing ? something(pattern_slot(e.code), _next_free_slot(ed)) : slot
    code = retarget_pattern(e.code, target)
    lines = collect(String, split(TK.text(ed), '\n'; keepempty = true))
    # Remplace le bloc du même slot s'il existe, sinon ajoute à la fin.
    head_rx = Regex("^\\s*@d$(target)\\b")
    idx = findfirst(l -> match(head_rx, l) !== nothing, lines)
    row = if idx === nothing
        isempty(strip(get(lines, length(lines), ""))) || push!(lines, "")
        r = length(lines) + 1
        append!(lines, split(code, '\n'))
        r
    else
        (a, b) = _logical_block_range(lines, idx)
        splice!(lines, a:max(b, a), split(code, '\n'))
        a
    end
    # `set_text!` repositionne le curseur : on le pose après.
    TK.set_text!(ed, join(lines, '\n'))
    ed.cursor_row = clamp(row, 1, length(ed.lines))
    ed.cursor_col = 0
    _push_app_log!(m, "[INFO] « $(e.name) » chargé sur d$target")
    _eval_current_line!(m)
    return true
end

# Charge l'entrée sélectionnée depuis le modal.
function _patterns_load_selected!(m::RessacApp, slot::Union{Nothing,Int} = nothing)
    e = _pattern_cur(m)
    e === nothing && return
    m.modal = :none
    _load_pattern_cmd!(m, e.name, slot)
end

function _patterns_delete_selected!(m::RessacApp)
    e = _pattern_cur(m)
    e === nothing && return
    delete_pattern!(e.name)
    m.pat_cursor = max(1, m.pat_cursor - 1)
    _push_app_log!(m, "[INFO] pattern « $(e.name) » supprimé")
end

# ── Registre de touches ────────────────────────────────────────────
scope!(:modal_patterns, "Patterns rangés")
bind!(:modal_patterns, "Enter", "charger"; short = "charger", group = :edit,
      action = m -> _patterns_load_selected!(m))
bind!(:modal_patterns, ["1", "2", "3", "4", "5", "6", "7", "8", "9"], "charger sur le slot N";
      short = "slot N", group = :edit,
      action = (m, evt) -> _patterns_load_selected!(m, Int(evt.char - '0')))
bind!(:modal_patterns, "/", "chercher"; short = "chercher", group = :nav,
      action = m -> (m.pat_search_mode = true))
bind!(:modal_patterns, ["j", "↓"], "suivant"; group = :nav, hint = false, repeat = true,
      action = m -> (m.pat_cursor = min(m.pat_cursor + 1, max(1, length(_pattern_entries(m))))))
bind!(:modal_patterns, ["k", "↑"], "précédent"; group = :nav, hint = false, repeat = true,
      action = m -> (m.pat_cursor = max(1, m.pat_cursor - 1)))
bind!(:modal_patterns, "g", "premier"; group = :nav, hint = false,
      action = m -> (m.pat_cursor = 1))
bind!(:modal_patterns, "G", "dernier"; group = :nav, hint = false,
      action = m -> (m.pat_cursor = max(1, length(_pattern_entries(m)))))
bind!(:modal_patterns, "x", "supprimer"; group = :edit,
      action = m -> _patterns_delete_selected!(m))
_bind_modal_common!(:modal_patterns)
