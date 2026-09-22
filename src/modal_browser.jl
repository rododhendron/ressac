# Browser modal — unified picker over registered samples,
# instruments and synths. Owns the open/handle/preview/insert/render
# path AND the shared types/helpers (`_BrowserEntry`, the three
# `_*_summary` rendering helpers, and the `_PREVIEW_CUT_GROUP`
# constant — moved here from the deleted tui_browser.jl).

"""
    _BrowserEntry(kind, name, plugin, summary)

Unified picker row. Carries enough metadata to render a one-line
summary and dispatch a preview without re-querying the registry.
"""
struct _BrowserEntry
    kind::Symbol      # :instrument | :sample | :synth
    name::Symbol
    plugin::String
    summary::String
end

# Preview-fire cut group: any sound previewed via `K` / Space uses
# this group so that consecutive previews truncate each other —
# you don't get a wash of overlapping samples when scanning the list
# quickly. SuperDirt voices sharing a positive `cut` int are
# mutually exclusive.
const _PREVIEW_CUT_GROUP = 9999

function _instrument_summary(e::InstrumentEntry)
    s_target = ""
    parts = String[]
    for (k, v) in e.params
        if k == "s"
            s_target = String(v)
        else
            push!(parts, "$k=$v")
        end
    end
    desc = get(e.metadata, "description", "")
    tail = isempty(desc) ? "" : "  — $desc"
    head = isempty(s_target) ? "" : "$(s_target)  "
    return head * join(parts, ", ") * tail
end

function _sample_summary(e::SampleEntry)
    nv = length(e.variants)
    tags = get(e.metadata, "tags", String[])
    tag_str = isempty(tags) ? "" : "  [" * join(tags, ", ") * "]"
    bpm = get(e.metadata, "bpm", nothing)
    bpm_str = bpm === nothing ? "" : "  $(bpm) BPM"
    return "$(nv)v$tag_str$bpm_str"
end

function _synth_summary(e::SynthEntry)
    tags = get(e.metadata, "tags", String[])
    tag_str = isempty(tags) ? "" : "[" * join(tags, ", ") * "]"
    desc = get(e.metadata, "description", "")
    parts = String[]
    isempty(tag_str) || push!(parts, tag_str)
    isempty(desc) || push!(parts, desc)
    return join(parts, "  ")
end

function _open_browser!(m::RessacApp)
    _open_modal!(m, :browse, :browser_cursor)
    m.browser_query = ""
    m.browser_filter = :all
    m.browser_search_mode = false
end

# Largeur d'une case de la grille : assez pour un nom de son + la marge.
const _BROWSER_CELL_W = 22
_browser_cols(width::Int) = max(1, width ÷ _BROWSER_CELL_W)

"""
    _browser_move!(m, d) -> Bool

Déplace le curseur de `d` cases dans la grille (±1 = voisin,
±`browser_cols` = ligne au-dessus / en dessous), en restant dans la liste.
"""
function _browser_move!(m::RessacApp, d::Int)
    n = length(_browser_entries(m))
    n == 0 && return true
    m.browser_cursor = clamp(m.browser_cursor + d, 1, n)
    return true
end

function _browser_entries(m::RessacApp)
    out = _BrowserEntry[]
    if m.browser_filter === :all || m.browser_filter === :instruments
        for e in values(_INSTRUMENT_REGISTRY)
            push!(out, _BrowserEntry(:instrument, e.name, e.plugin, _instrument_summary(e)))
        end
    end
    if m.browser_filter === :all || m.browser_filter === :samples
        for e in values(_SAMPLE_REGISTRY)
            push!(out, _BrowserEntry(:sample, e.name, e.plugin, _sample_summary(e)))
        end
    end
    if m.browser_filter === :all || m.browser_filter === :synths
        for e in values(_SYNTH_REGISTRY)
            push!(out, _BrowserEntry(:synth, e.name, e.plugin, _synth_summary(e)))
        end
    end
    isempty(m.browser_query) || (out = filter(e -> _fuzzy_score(m.browser_query, String(e.name)) !== nothing, out))
    sort!(out; by = e -> (String(e.kind), String(e.name)))
    return out
end

function _handle_browser_key!(m::RessacApp, evt::TK.KeyEvent)
    # ── Mode recherche (`/`) : toute la frappe va dans la requête, pour
    # pouvoir chercher « jazz » sans que j et a soient des raccourcis.
    if m.browser_search_mode
        if evt.key === :escape
            m.browser_search_mode = false
            m.browser_query = ""
            m.browser_cursor = 1
            return
        elseif evt.key === :enter
            m.browser_search_mode = false
            return
        elseif evt.key === :backspace
            isempty(m.browser_query) ||
                (m.browser_query = m.browser_query[1:prevind(m.browser_query, end)])
            m.browser_cursor = 1
            return
        elseif evt.key === :char && evt.char != '\0' && _is_typable_ascii(evt.char)
            m.browser_query *= string(evt.char)
            m.browser_cursor = 1
            return
        end
        # flèches, Tab… passent à la navigation normale
    end
    # Esc ferme, sauf si un filtre est posé : il l'efface d'abord.
    if evt.key === :escape || evt.char == 'q'
        if isempty(m.browser_query)
            m.modal = :none
        else
            m.browser_query = ""
            m.browser_cursor = 1
        end
        return
    end
    dispatch!(((:modal_browse, m),), evt) && return
    return
end

function _browser_preview!(m::RessacApp, entry::_BrowserEntry)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    now = time()
    now - m.browser_last_preview < 0.05 && return
    m.browser_last_preview = now
    args = Any[]
    if entry.kind === :instrument
        instr = instrument_info(entry.name)
        instr === nothing && return
        for (k, v) in instr.params
            converted = _osc_value(v)
            converted === missing && continue
            push!(args, k); push!(args, converted)
        end
    elseif entry.kind === :sample
        push!(args, "s"); push!(args, String(entry.name))
    elseif entry.kind === :synth
        push!(args, "s"); push!(args, String(entry.name))
        push!(args, "release"); push!(args, Float32(0.4))
    end
    push!(args, "cut"); push!(args, Int32(_PREVIEW_CUT_GROUP))
    send_osc(sched.osc, encode(OSCMessage("/dirt/play", args)))
end

function _browser_insert!(m::RessacApp, entry::_BrowserEntry)
    ed = _active_editor(m)
    ed === nothing && return
    txt = TK.text(ed)
    lines = collect(split(txt, '\n'; keepempty=true))
    row = ed.cursor_row
    1 <= row <= length(lines) || (push!(lines, ""); row = length(lines))
    line = lines[row]
    col = clamp(ed.cursor_col, 0, lastindex(line))
    name = String(entry.name)
    prefix = col > 0 ? line[1:col] : ""
    suffix = col >= lastindex(line) ? "" : line[col+1:end]
    lines[row] = prefix * name * suffix
    TK.set_text!(ed, join(lines, '\n'))
    ed.cursor_col = lastindex(prefix) + lastindex(name)
    _push_app_log!(m, "[INFO] $(entry.kind) $name inséré")
end

function _render_browser_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    entries = _browser_entries(m)
    n = length(entries)
    inner = _render_modal_block!(buf, area;
        title = "SONS",
        title_right = _modal_hint_text(m, :modal_browse),
        w_max = 120,
        h_target = max(14, min(area.height - 4, n + 8)))
    inner.width < 20 && return
    # ── Row 1: category tab strip ─────────────────────────────────
    filters = (:all, :instruments, :samples, :synths)
    tab_x = inner.x
    for (i, f) in enumerate(filters)
        label = String(f)
        chip  = " " * label * " "
        is_active = f === m.browser_filter
        sty = is_active ? TK.tstyle(:accent, bold = true) :
                          TK.tstyle(:text_dim)
        tab_x + textwidth(chip) > inner.x + inner.width && break
        TK.set_string!(buf, tab_x, inner.y, chip, sty)
        tab_x += textwidth(chip)
        if i < length(filters) && tab_x + 2 < inner.x + inner.width
            TK.set_string!(buf, tab_x, inner.y, "·", TK.tstyle(:text_dim))
            tab_x += 1
        end
    end
    # ── Row 2: search bar ─────────────────────────────────────────
    count_txt = "$(n) son$(n == 1 ? "" : "s")" *
                (n == 0 ? "" : "  ·  $(m.browser_cursor)/$n")
    sb_text = m.browser_search_mode ? "⌕ " * m.browser_query * "▏" :
              isempty(m.browser_query) ? "/ pour chercher" : "⌕ " * m.browser_query
    sb_style = m.browser_search_mode ? TK.tstyle(:accent, bold = true) :
               isempty(m.browser_query) ? TK.tstyle(:text_dim) : TK.tstyle(:text)
    TK.set_string!(buf, inner.x, inner.y + 1,
                   first(rpad(sb_text, max(0, inner.width - textwidth(count_txt))),
                         max(0, inner.width - textwidth(count_txt))), sb_style)
    TK.set_string!(buf, inner.x + inner.width - textwidth(count_txt), inner.y + 1,
                   count_txt, TK.tstyle(:text_dim))
    # ── Grille : les noms en colonnes, le détail de la sélection en bas ──
    body_y = inner.y + 2
    body_h = max(1, inner.height - 3)            # -1 pour la ligne de détail
    ncols = _browser_cols(inner.width)
    cell_w = inner.width ÷ ncols
    m.browser_cols = ncols
    m.browser_rows = body_h
    nrows_total = cld(max(n, 1), ncols)
    cur_row = cld(max(m.browser_cursor, 1), ncols)
    m.modal_scroll = _scroll_to_show(cur_row, nrows_total, body_h, m.modal_scroll)
    for r in 1:body_h
        row = m.modal_scroll + r
        row > nrows_total && break
        for c in 1:ncols
            idx = (row - 1) * ncols + c
            idx > n && break
            e = entries[idx]
            kind_letter = e.kind === :instrument ? "I" :
                          e.kind === :sample     ? "S" : "Y"
            sel = idx == m.browser_cursor
            label = "$(sel ? "▶" : " ")$kind_letter $(String(e.name))"
            style = sel ? TK.tstyle(:accent, bold = true) :
                    e.kind === :sample ? TK.tstyle(:text) : TK.tstyle(:text_bright)
            TK.set_string!(buf, inner.x + (c - 1) * cell_w, body_y + r - 1,
                           first(rpad(label, cell_w), cell_w), style)
        end
    end
    # Détail de la sélection (le résumé ne tient pas dans une case).
    if 1 <= m.browser_cursor <= n
        e = entries[m.browser_cursor]
        detail = "$(e.kind) $(e.name)  ·  $(e.plugin)" * (isempty(e.summary) ? "" : "  ·  $(e.summary)")
        TK.set_string!(buf, inner.x, inner.y + inner.height - 1,
                       first(rpad(detail, inner.width), inner.width), TK.tstyle(:text_dim))
    end
end

# ── Registre de touches (déclaré en fin de fichier : les actions nommées
#    doivent exister au moment du bind!) ──
_browser_cur(m::RessacApp) = (e = _browser_entries(m); 1 <= m.browser_cursor <= length(e) ? e[m.browser_cursor] : nothing)
scope!(:modal_browse, "Sons (samples, instruments, synths)")
bind!(:modal_browse, "Enter", "insérer dans le pattern"; short = "insérer", group = :edit,
      action = m -> (e = _browser_cur(m); e === nothing || _browser_insert!(m, e); m.modal = :none))
bind!(:modal_browse, ["K", "Space"], "écouter"; group = :audio,
      action = m -> (e = _browser_cur(m); e === nothing || _browser_preview!(m, e)))
bind!(:modal_browse, "Tab", "catégorie suivante"; group = :nav,
      action = m -> (filters = (:all, :instruments, :samples, :synths);
                     i = findfirst(==(m.browser_filter), filters);
                     m.browser_filter = filters[(i % length(filters)) + 1];
                     m.browser_cursor = 1))
bind!(:modal_browse, "/", "chercher"; short = "chercher", group = :nav,
      action = m -> (m.browser_search_mode = true))
bind!(:modal_browse, ["h", "←"], "précédent"; group = :nav, hint = false, repeat = true,
      action = m -> _browser_move!(m, -1))
bind!(:modal_browse, ["l", "→"], "suivant"; group = :nav, hint = false, repeat = true,
      action = m -> _browser_move!(m, 1))
bind!(:modal_browse, ["j", "↓"], "ligne suivante"; group = :nav, hint = false, repeat = true,
      action = m -> _browser_move!(m, m.browser_cols))
bind!(:modal_browse, ["k", "↑"], "ligne précédente"; group = :nav, hint = false, repeat = true,
      action = m -> _browser_move!(m, -m.browser_cols))
bind!(:modal_browse, "Ctrl-d", "page suivante"; group = :nav, hint = false, repeat = true,
      action = m -> _browser_move!(m, m.browser_cols * m.browser_rows))
bind!(:modal_browse, "Ctrl-u", "page précédente"; group = :nav, hint = false, repeat = true,
      action = m -> _browser_move!(m, -m.browser_cols * m.browser_rows))
bind!(:modal_browse, "g", "premier"; group = :nav, hint = false,
      action = m -> (m.browser_cursor = 1))
bind!(:modal_browse, "G", "dernier"; group = :nav, hint = false,
      action = m -> (m.browser_cursor = max(1, length(_browser_entries(m)))))
bind!(:modal_browse, "Bksp", "effacer le filtre"; group = :edit, hint = false,
      when = m -> !isempty(m.browser_query),
      action = m -> (m.browser_query = m.browser_query[1:prevind(m.browser_query, end)];
                     m.browser_cursor = 1))
_bind_modal_common!(:modal_browse)
