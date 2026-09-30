# src/app_hover.jl
# La bulle de glossaire au survol. La souris s'arrête sur un terme
# souligné : une bulle s'ouvre à côté avec sa définition. Elle se
# verrouille après `hover_lock_ms` (ou dès que la souris y entre) ; une
# fois verrouillée, survoler un terme dans la bulle en ouvre une autre à
# côté, et sortir de toutes les bulles ferme tout. Esc ferme aussi ; une
# touche quelconque aussi (c'est un objet de la souris).

_hover_box_w(area) = clamp(area.width ÷ 2, 24, 48)

function _hover_scrollpane(pane)
    pane isa DocPane      && return pane.pane
    pane isa SynthDocPane && return _synthdoc_view(pane)
    pane isa WikiPane     && return pane.pane
    pane isa TutorialPane && return pane.view
    pane isa LogPane      && return pane.pane
    pane isa WaveformPane && pane.sculpt && !pane.linked && return pane.explain_view
    return nothing
end

# (texte, colonne) sous (x, y) dans un ScrollPane rendu, ou nothing.
function _scrollpane_line_at(sp::TK.ScrollPane, x::Int, y::Int)
    a = sp.last_area
    (a.width <= 0 || a.height <= 0) && return nothing
    (a.x <= x < a.x + a.width && a.y <= y < a.y + a.height) || return nothing
    c = sp.content
    c isa Tuple && return nothing
    i = sp.offset + (y - a.y) + 1
    1 <= i <= length(c) || return nothing
    line = c[i]
    text = line isa AbstractString ? String(line) : join(sp.content for sp in line)
    return (text, x - a.x + 1)
end

"""
    _hover_term_at(m, x, y) -> Union{Nothing,String}

Le terme du glossaire sous la souris : dans une pane à texte (doc, wiki,
tutoriel, journal, explication) ou dans l'éditeur focalisé.
"""
function _hover_term_at(m::RessacApp, x::Int, y::Int)
    ws = current_workspace(m.workspaces)
    (ws === nothing || m._last_ws_area === nothing) && return nothing
    rects = _workspace_rects(m, ws, m._last_ws_area)
    for (leaf_id, r) in rects
        _in_rect_xywh(r.x, r.y, r.w, r.h, x, y) || continue
        leaf = _find_leaf_by_id(ws.tree, leaf_id)
        (leaf isa PaneLeaf && 1 <= leaf.current_tab <= length(leaf.tabs)) || return nothing
        pane = leaf.tabs[leaf.current_tab]
        sp = _hover_scrollpane(pane)
        if sp !== nothing
            hit = _scrollpane_line_at(sp, x, y)
            hit === nothing && return nothing
            return _glossary_term_at(hit[1], hit[2])
        end
        if pane isa EditorPane && leaf_id == ws.focused_pane
            rect = _focused_editor_rect(m)
            rect === nothing && return nothing
            ed = _active_editor(m)
            ed === nothing && return nothing
            rc = _screen_to_editor_pos(ed, rect, x, y)
            rc === nothing && return nothing
            (row, col) = rc
            1 <= row <= length(ed.lines) || return nothing
            return _glossary_term_at(String(ed.lines[row]), col + 1)
        end
        return nothing
    end
    return nothing
end

_hover_in_box(b::HoverBox, x::Int, y::Int) = b.x <= x < b.x + b.w && b.y <= y < b.y + b.h

# Le terme sous (x, y) dans le texte d'une bulle.
function _hover_box_term_at(b::HoverBox, x::Int, y::Int)
    i = y - b.y
    1 <= i <= length(b.lines) || return nothing
    text = join(sp.content for sp in b.lines[i])
    return _glossary_term_at(text, x - b.x)
end

function _hover_make_box(m::RessacApp, term::AbstractString, x::Int, y::Int)
    area = m._last_ws_area
    W = area === nothing ? 120 : area.x + area.w
    H = area === nothing ? 40 : area.y + area.h
    w = _hover_box_w((width = W, height = H))
    lines = _glossary_lines(term, w - 4)
    h = min(length(lines) + 2, 16)
    bx = x + w + 1 <= W ? x : max(1, x - w)
    by = y + h <= H + 1 ? y : max(1, y - h)
    return HoverBox(String(term), bx, by, w, h, lines)
end

function _hover_open!(m::RessacApp, term::AbstractString, x::Int, y::Int)
    m.hover = HoverState([_hover_make_box(m, term, x + 2, y + 1)], _HOVER_CLOCK[](), false)
    return
end

_hover_close!(m::RessacApp) = (m.hover = nothing; nothing)

_hover_lock_ms(m::RessacApp) = ressac_config().hover_lock_ms

# Le temps verrouille la bulle du dessus.
function _hover_tick!(m::RessacApp)
    h = m.hover
    h === nothing && return
    h.locked && return
    (_HOVER_CLOCK[]() - h.since) * 1000 >= _hover_lock_ms(m) && (h.locked = true)
    return
end

"""
    _hover_mouse!(m, evt) -> Bool

Suit la souris pour le glossaire. Vrai quand l'événement est consommé
(un déplacement, ou un clic dans une bulle).
"""
function _hover_mouse!(m::RessacApp, evt::TK.MouseEvent)
    ressac_config().hover || return false
    x, y = evt.x, evt.y
    _hover_tick!(m)
    h = m.hover
    if evt.action === TK.mouse_move
        if h !== nothing
            i = findlast(b -> _hover_in_box(b, x, y), h.boxes)
            if i !== nothing
                h.locked = true
                term = _hover_box_term_at(h.boxes[i], x, y)
                if term !== nothing && term != h.boxes[i].term &&
                   !(i < length(h.boxes) && h.boxes[i + 1].term == term)
                    resize!(h.boxes, i)
                    b = h.boxes[i]
                    push!(h.boxes, _hover_make_box(m, term, b.x + b.w + 1, y))
                    h.since = _HOVER_CLOCK[]()
                end
                return true
            end
            if h.locked
                _hover_close!(m)          # sortie de la souris : tout se ferme
                return true
            end
            term = _hover_term_at(m, x, y)
            term == h.boxes[1].term && return true
            term === nothing ? _hover_close!(m) : _hover_open!(m, term, x, y)
            return true
        end
        term = _hover_term_at(m, x, y)
        term === nothing && return false
        _hover_open!(m, term, x, y)
        return true
    end
    h === nothing && return false
    if evt.action === TK.mouse_press
        if any(b -> _hover_in_box(b, x, y), h.boxes)
            h.locked = true
            return true
        end
        _hover_close!(m)
    end
    return false
end

# Une touche ferme la bulle ; Esc est consommé, le reste continue.
function _stage_hover!(m::RessacApp, evt::TK.KeyEvent)
    m.hover === nothing && return false
    evt.action === TK.key_press || return false
    _hover_close!(m)
    return evt.key === :escape
end

function _render_hover!(m::RessacApp, buf::TK.Buffer)
    _hover_tick!(m)
    h = m.hover
    h === nothing && return
    for b in h.boxes
        rect = TK.Rect(b.x, b.y, b.w, b.h)
        for yy in b.y:(b.y + b.h - 1)
            TK.set_string!(buf, b.x, yy, " "^b.w, TK.tstyle(:text))
        end
        old = _PANE_FOCUS_COLOR[]
        _PANE_FOCUS_COLOR[] = h.locked ? TK.theme().accent : nothing
        try
            _render_pane_block_simple!(rect, b.term, buf)
        finally
            _PANE_FOCUS_COLOR[] = old
        end
        inner = _inner_rect_simple(rect)
        for (i, line) in enumerate(b.lines)
            i > inner.height && break
            x = inner.x + 1
            for sp in line
                TK.set_string!(buf, x, inner.y + i - 1, sp.content, sp.style)
                x += textwidth(sp.content)
            end
        end
    end
    return
end

# ── Le terminal : suivre la souris sans bouton (mode 1003) ───────────
function _request_mouse_motion()
    try
        isa(stdout, Base.TTY) || return nothing
        write(stdout, "\e[?1003h"); flush(stdout)
    catch
    end
    return nothing
end
function _release_mouse_motion()
    try
        isa(stdout, Base.TTY) || return nothing
        write(stdout, "\e[?1003l"); flush(stdout)
    catch
    end
    return nothing
end
