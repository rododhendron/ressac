# src/rack_view.jl
# Bandeau des slots — ce qui est chargé, d'un coup d'œil, au-dessus des
# panes. Une ligne par slot, sa couleur, son motif sur le cycle courant
# avec le pas en train de sonner, et son état muet.
#
# La hauteur suit le nombre de slots : rien de chargé, rien affiché.
# `:slots` l'allume et l'éteint, un clic sur une ligne coupe ou remet le
# slot.

const _RACK_MAX_ROWS = 8        # au-delà, une ligne « +N autres »

"""
    _rack_slots(m) -> Vector{Tuple{Symbol,Any,Bool}}

Les slots à montrer : ceux qui jouent, puis ceux qu'on a coupés (ils
restent visibles, en gris, parce qu'ils font partie du morceau).
"""
function _rack_slots(m::RessacApp)
    out = Tuple{Symbol,Any,Bool}[]
    for (slot, pat) in m.scheduler.patterns
        push!(out, (slot, pat, false))
    end
    for (slot, pat) in _APP_MUTED_PATTERNS
        haskey(m.scheduler.patterns, slot) || push!(out, (slot, pat, true))
    end
    sort!(out; by = t -> something(tryparse(Int, SubString(String(t[1]), 2)), 999))
    return out
end

"""
    _rack_height(m) -> Int

La hauteur du bandeau : une ligne par slot, zéro quand il n'y a rien ou
qu'on l'a éteint. Jamais plus de la moitié de la fenêtre.
"""
function _rack_height(m::RessacApp, avail::Int = 999)
    m.rack_visible || return 0
    n = length(_rack_slots(m))
    n == 0 && return 0
    rows = min(n, _RACK_MAX_ROWS) + (n > _RACK_MAX_ROWS ? 1 : 0)
    return clamp(rows, 0, max(0, avail ÷ 2))
end

# Le motif d'un slot sur le cycle courant, en `steps` pas.
function _rack_grid(m::RessacApp, slot::Symbol, pat, cyc::Int, steps::Int)
    key = (slot, cyc, steps)
    cached = get(m.rack_cache, slot, nothing)
    cached !== nothing && cached[1] == key && return cached[2]
    grid = fill('·', steps)
    label = ""
    try
        evs = Base.invokelatest(pat, Rational{Int64}(cyc), Rational{Int64}(cyc + 1))
        names = String[]
        for ev in evs
            pos = Float64(ev.start - floor(ev.start))
            k = clamp(floor(Int, pos * steps) + 1, 1, steps)
            grid[k] = 'x'
            nm = _note_name(ev.value)
            isempty(nm) || nm in names || push!(names, nm)
        end
        label = join(first(names, 3), " ")
    catch
    end
    res = (String(grid), label)
    m.rack_cache[slot] = (key, res)
    return res
end

"""
    _render_rack!(m, rect, buf)

Dessine le bandeau. Chaque ligne est cliquable : couper ou remettre le
slot.
"""
function _render_rack!(m::RessacApp, rect::TK.Rect, buf::TK.Buffer)
    rect.height >= 1 || return
    empty!(m._rack_hits)
    m._rack_y0 = rect.y
    slots = _rack_slots(m)
    isempty(slots) && return
    sched = m.scheduler
    cyc = sched.t_start > 0 ? floor(Int, (time() - sched.t_start) * sched.cps) : 0
    phase = sched.t_start > 0 ? mod((time() - sched.t_start) * sched.cps, 1.0) : 0.0
    steps = rect.width >= 46 ? 16 : 8
    # S'il y a plus de slots que de place, la dernière ligne est le
    # récapitulatif : on lui garde sa place plutôt que de la perdre.
    shown = min(length(slots), rect.height, _RACK_MAX_ROWS)
    length(slots) > shown && (shown = max(1, min(rect.height - 1, _RACK_MAX_ROWS)))
    for i in 1:shown
        (slot, pat, muted) = slots[i]
        y = rect.y + i - 1
        x = rect.x
        col = muted ? TK.theme().text_dim : _slot_color(slot)
        lbl = rpad(String(slot), 4)
        TK.set_string!(buf, x, y, lbl, TK.Style(fg = col, bold = !muted))
        x += textwidth(lbl)
        # État : ▸ joue, ⏸ coupé.
        mark = muted ? "⏸ " : "▸ "
        TK.set_string!(buf, x, y, mark, TK.Style(fg = col))
        x += textwidth(mark)
        grid, label = _rack_grid(m, slot, pat, cyc, steps)
        if x + steps + 2 <= rect.x + rect.width
            TK.set_string!(buf, x, y, "│", TK.tstyle(:border)); x += 1
            cur = clamp(floor(Int, phase * steps) + 1, 1, steps)
            for (k, ch) in enumerate(grid)
                sty = if muted
                    TK.tstyle(:text_dim)
                elseif k == cur
                    TK.Style(fg = TK.theme().bg, bg = col, bold = true)
                elseif ch == 'x'
                    TK.Style(fg = col, bold = true)
                else
                    TK.tstyle(:text_dim)
                end
                TK.set_char!(buf, x, y, ch, sty)
                x += 1
            end
            TK.set_string!(buf, x, y, "│", TK.tstyle(:border)); x += 2
        end
        if !isempty(label) && x < rect.x + rect.width
            TK.set_string!(buf, x, y, first(label, rect.x + rect.width - x),
                           muted ? TK.tstyle(:text_dim) : TK.tstyle(:text))
        end
        push!(m._rack_hits, (y, slot))
    end
    if length(slots) > shown && rect.height > shown
        TK.set_string!(buf, rect.x, rect.y + shown,
                       first("+$(length(slots) - shown) autres slots", rect.width),
                       TK.tstyle(:text_dim))
    end
    return
end

"""
    _rack_click!(m, y) -> Bool

Un clic sur une ligne du bandeau coupe ou remet le slot.
"""
function _rack_click!(m::RessacApp, y::Int)
    for (ry, slot) in m._rack_hits
        ry == y || continue
        if haskey(m.scheduler.patterns, slot)
            _mute_pattern_slot!(m, slot)
        else
            _unmute_pattern_slot!(m, slot)
        end
        return true
    end
    return false
end

"""
    _toggle_rack!(m)

`:slots` — affiche ou masque le bandeau.
"""
function _toggle_rack!(m::RessacApp)
    m.rack_visible = !m.rack_visible
    _push_app_log!(m, m.rack_visible ?
        "[INFO] bandeau des slots affiché — un clic sur une ligne coupe ou remet le slot" :
        "[INFO] bandeau des slots masqué")
    return
end
