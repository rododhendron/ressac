# src/modal_evolve.jl
# Modal « VARIATIONS » — on part du bloc sous le curseur, on écoute des
# variantes, on verrouille celles qui plaisent et on relance depuis
# elles. Ce qu'on garde s'écrit dans le buffer ou se range d'une touche.

const _EVOLVE_SLOT = 64        # slot d'écoute, hors des seize premiers

function _open_evolve_modal!(m::RessacApp)
    seed = _block_under_cursor(m)
    if seed === nothing || isempty(strip(seed)) || pattern_slot(seed) === nothing
        _push_app_log!(m, "[WARN] :vary — pose le curseur sur un bloc @dN à faire varier")
        return
    end
    m.evolve_seed = strip(String(seed))
    m.evolve_locked = String[]
    m.evolve_gen = 1
    _evolve_breed!(m)
    _open_modal!(m, :evolve, :evolve_cursor)
    _push_app_log!(m, "[INFO] variations — Espace écoute · l verrouille · r relance · Entrée remplace le bloc · K range")
end

"""
    _evolve_breed!(m)

Remplit la liste de candidats depuis les graines : les verrouillés s'ils
existent, sinon le bloc de départ.
"""
function _evolve_breed!(m::RessacApp)
    seeds = isempty(m.evolve_locked) ? String[m.evolve_seed] :
            vcat(m.evolve_locked, m.evolve_seed)
    kept = copy(m.evolve_locked)
    fresh = evolve_patterns(seeds, max(1, m.evolve_count - length(kept)); rng = m.evolve_rng)
    m.evolve_items = vcat(kept, fresh)
    m.evolve_cursor = clamp(m.evolve_cursor, 1, max(1, length(m.evolve_items)))
    return m.evolve_items
end

_evolve_cur(m::RessacApp) =
    1 <= m.evolve_cursor <= length(m.evolve_items) ? m.evolve_items[m.evolve_cursor] : nothing

_evolve_is_locked(m::RessacApp, code::AbstractString) = code in m.evolve_locked

function _evolve_toggle_lock!(m::RessacApp)
    code = _evolve_cur(m)
    code === nothing && return
    if code in m.evolve_locked
        filter!(!=(code), m.evolve_locked)
    else
        push!(m.evolve_locked, code)
    end
end

# Joue le candidat sur un slot d'écoute dédié, sans toucher aux slots joués.
function _evolve_preview!(m::RessacApp)
    code = _evolve_cur(m)
    code === nothing && return
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    try
        ex = Meta.parse(retarget_pattern(code, _EVOLVE_SLOT))
        Core.eval(Main, ex)
        _push_app_log!(m, "[INFO] variation sur d$(_EVOLVE_SLOT) — Espace pour la suivante, x coupe l'écoute")
    catch err
        _push_app_log!(m, "[ERROR] variation : $(sprint(showerror, err))")
    end
end

function _evolve_stop_preview!(m::RessacApp)
    sched = _LIVE_SCHEDULER[]
    sched === nothing && return
    unset_pattern!(sched, Symbol("d", _EVOLVE_SLOT))
end

# Remplace le bloc de départ par le candidat, dans le buffer.
function _evolve_accept!(m::RessacApp)
    code = _evolve_cur(m)
    code === nothing && return
    ed = _active_editor(m)
    ed === nothing && return
    _evolve_stop_preview!(m)
    slot = something(pattern_slot(m.evolve_seed), 1)
    final = retarget_pattern(code, slot)
    lines = collect(String, split(TK.text(ed), '\n'; keepempty = true))
    head_rx = Regex("^\\s*@d$(slot)\\b")
    idx = findfirst(l -> match(head_rx, l) !== nothing, lines)
    row = if idx === nothing
        push!(lines, final); length(lines)
    else
        (a, b) = _logical_block_range(lines, idx)
        splice!(lines, a:max(b, a), split(final, '\n'))
        a
    end
    TK.set_text!(ed, join(lines, '\n'))
    ed.cursor_row = clamp(row, 1, length(ed.lines))
    ed.cursor_col = 0
    m.modal = :none
    _push_app_log!(m, "[INFO] variation posée sur d$slot")
    _eval_current_line!(m)
end

# Range le candidat dans la bibliothèque, sous un nom dérivé.
function _evolve_keep!(m::RessacApp)
    code = _evolve_cur(m)
    code === nothing && return
    base = "var-" * Dates.format(Dates.now(), "HHMMSS")
    try
        e = save_pattern!(base, code; tags = ["variation"])
        _push_app_log!(m, "[INFO] variation rangée sous « $(e.name) » — :recall $(e.name) la rappelle")
    catch err
        _push_app_log!(m, "[ERROR] :keep — $(sprint(showerror, err))")
    end
end

function _handle_evolve_key!(m::RessacApp, evt::TK.KeyEvent)
    if evt.key === :escape || evt.char == 'q'
        _evolve_stop_preview!(m)
        m.modal = :none
        return
    end
    dispatch!(((:modal_evolve, m),), evt) && return
    return
end

function _render_evolve_modal!(m::RessacApp, area::TK.Rect, buf::TK.Buffer)
    items = m.evolve_items
    n = length(items)
    inner = _render_modal_block!(buf, area;
        title = "VARIATIONS · génération $(m.evolve_gen)",
        title_right = _modal_hint_text(m, :modal_evolve),
        w_max = 120,
        h_target = max(14, min(area.height - 4, n + 8)))
    inner.width < 24 && return
    lock_txt = "$(length(m.evolve_locked)) verrouillée$(length(m.evolve_locked) == 1 ? "" : "s")"
    TK.set_string!(buf, inner.x, inner.y,
                   first(rpad("départ : " * m.evolve_seed, max(0, inner.width - textwidth(lock_txt))),
                         max(0, inner.width - textwidth(lock_txt))),
                   TK.tstyle(:text_dim))
    TK.set_string!(buf, inner.x + inner.width - textwidth(lock_txt), inner.y,
                   lock_txt, TK.tstyle(:text_dim))
    body_y = inner.y + 2
    body_h = inner.height - 2
    m.modal_scroll = _scroll_to_show(m.evolve_cursor, n, body_h, m.modal_scroll)
    for i in 1:body_h
        idx = m.modal_scroll + i
        idx > n && break
        code = items[idx]
        sel = idx == m.evolve_cursor
        mark = _evolve_is_locked(m, code) ? "🔒" : (sel ? "▶ " : "  ")
        line = "$(mark) $(code)"
        style = sel ? TK.tstyle(:accent, bold = true) :
                _evolve_is_locked(m, code) ? TK.tstyle(:success) : TK.tstyle(:text)
        TK.set_string!(buf, inner.x, body_y + i - 1,
                       first(rpad(line, inner.width), inner.width), style)
    end
end

# ── Registre de touches ────────────────────────────────────────────
scope!(:modal_evolve, "Variations de pattern")
bind!(:modal_evolve, ["Space", "K"], "écouter"; short = "écouter", group = :audio,
      action = m -> _evolve_preview!(m))
bind!(:modal_evolve, "l", "verrouiller / relâcher"; short = "verrouiller", group = :edit,
      action = m -> _evolve_toggle_lock!(m))
bind!(:modal_evolve, "r", "relancer depuis les verrouillées"; short = "relancer", group = :edit,
      action = m -> (m.evolve_gen += 1; _evolve_breed!(m)))
bind!(:modal_evolve, "Enter", "remplacer le bloc"; short = "remplacer", group = :edit,
      action = m -> _evolve_accept!(m))
bind!(:modal_evolve, "s", "ranger dans la bibliothèque"; short = "ranger", group = :file,
      action = m -> _evolve_keep!(m))
bind!(:modal_evolve, "x", "couper l'écoute"; group = :audio, hint = false,
      action = m -> _evolve_stop_preview!(m))
bind!(:modal_evolve, ["j", "↓"], "suivant"; group = :nav, hint = false, repeat = true,
      action = m -> (m.evolve_cursor = min(m.evolve_cursor + 1, max(1, length(m.evolve_items)))))
bind!(:modal_evolve, ["k", "↑"], "précédent"; group = :nav, hint = false, repeat = true,
      action = m -> (m.evolve_cursor = max(1, m.evolve_cursor - 1)))
_bind_modal_common!(:modal_evolve)
