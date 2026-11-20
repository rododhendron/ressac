# src/slot_marks.jl
# Ce que l'écran dit de chaque ligne @dN, sur la ligne elle-même :
#   • un SIGNE dans la colonne de gauche (une note dont la valeur suit la
#     vitesse du pattern, un silence pour un slot muet, un dièse pour un
#     texte modifié, un point d'orgue pour un drone…) ;
#   • le FOND de la ligne, qui s'allume au coup et retombe ;
#   • la GRILLE du cycle, une colonne fixe à droite du texte : un temps sur
#     deux a un fond, chaque ligne @dN y a sa piste nommée, la tête de
#     lecture la traverse de haut en bas ;
#   • l'ERREUR, écrite dans la grille à la place de la piste fautive.
#
# La couleur dit l'état, jamais l'identité d'un slot : vert = joue, discret =
# muet, rouge = erreur, orange = la ligne du curseur.
#
# Tout est dessiné par-dessus le rendu de l'éditeur : le texte n'est jamais
# déplacé. L'état vient de app_slots.jl ; rien n'est décidé ici.

# ── Les signes ───────────────────────────────────────────────────────

"""
Une famille de signes de marge. `notes` et `rests` vont de la ronde à la
triple croche (voir `_note_value`).
"""
struct MarkSet
    notes::NTuple{6,Char}
    rests::NTuple{6,Char}
    modified::Char
    error::Char
    held::Char
    offgrid::Char
end

const _MARK_SETS = Dict{Symbol,MarkSet}(
    # Des signes de partition : la note dit la vitesse, le soupir se tait, le
    # dièse altère, le point d'orgue tient, la petite note barrée se joue
    # hors du temps. (Bloc Unicode « Musical Symbols », U+1D100.)
    :solfege => MarkSet(('\U1D15D', '\U1D15E', '\U1D15F', '\U1D160', '\U1D161', '\U1D162'),
                        ('\U1D13B', '\U1D13C', '\U1D13D', '\U1D13E', '\U1D13F', '\U1D13F'),
                        '♯', '✗', '\U1D110', '\U1D194'),
    # Les signes d'un lecteur.
    :transport => MarkSet(ntuple(_ -> '▶', 6), ntuple(_ -> '‖', 6), '✎', '✗', '⌒', '↯'),
    # Une famille de ronds, présente dans toute police.
    :formes => MarkSet(ntuple(_ -> '●', 6), ntuple(_ -> '○', 6), '◐', '⊗', '◉', '◌'),
)

const _SOLFEGE_FONT_OK = Ref{Union{Nothing,Bool}}(nothing)

# Une police installée couvre-t-elle les signes de solfège ? Demandé une fois
# à fontconfig ; sans réponse (pas de `fc-list`, autre système) on ne
# suppose rien : le solfège reste un choix explicite.
function _solfege_font_available()
    _SOLFEGE_FONT_OK[] === nothing || return _SOLFEGE_FONT_OK[]::Bool
    ok = try
        fc = Sys.which("fc-list")
        fc !== nothing && !isempty(strip(read(`$fc :charset=1d13d\ 1d110\ 1d161 family`, String)))
    catch
        false
    end
    _SOLFEGE_FONT_OK[] = ok
    return ok
end

"""
    _mark_set() -> MarkSet

La famille choisie par `ui.marks` ; `:auto` prend le solfège si une police
le couvre, les signes de lecteur sinon.
"""
function _mark_set()
    want = ressac_config().marks
    want === :auto && (want = _solfege_font_available() ? :solfege : :transport)
    return get(_MARK_SETS, want, _MARK_SETS[:transport])
end

"""
    _mark_char(line, set) -> Union{Nothing,Char}

Le signe d'une ligne. Rien pour une ligne à l'arrêt : une session rouverte
en silence ne doit pas se couvrir de signes.
"""
function _mark_char(l::SlotLine, set::MarkSet)
    l.state === :error && return set.error
    l.state === :muted && return set.rests[3]
    l.state === :modified && return set.modified
    l.state === :playing || return nothing
    l.held && return set.held
    l.offgrid && return set.offgrid
    return set.notes[max(_note_value(l.onsets), 1)]
end

# ── La piste ─────────────────────────────────────────────────────────

const _LANE_LEVELS = ('▁', '▂', '▃', '▄', '▅', '▆', '▇', '█')
const _LANE_WIDE   = 48
const _LANE_NARROW = 24

"""
    _lane_cells(events, cycle, width) -> Vector{Char}

Un cycle en `width` cellules : `' '` où rien ne commence, un bloc là où un
événement commence. Quand le pattern a des hauteurs, la taille du bloc dit
la hauteur relative dans le cycle (grave en bas) ; sinon le bloc est plein.
"""
function _lane_cells(events, cycle::Integer, width::Integer)
    cells = fill(' ', width)
    isempty(events) && return cells
    rows = Union{Nothing,Float64}[_note_row(ev.value) for ev in events]
    pitched = [r for r in rows if r !== nothing]
    lo, hi = isempty(pitched) ? (0.0, 0.0) : extrema(pitched)
    for (ev, r) in zip(events, rows)
        pos = Float64(ev.start) - cycle
        0 <= pos < 1 || continue
        k = clamp(floor(Int, pos * width) + 1, 1, width)
        ch = if r === nothing || hi == lo
            '█'
        else
            _LANE_LEVELS[clamp(1 + round(Int, (r - lo) / (hi - lo) * 7), 1, 8)]
        end
        # Deux événements dans la même cellule : le plus haut se voit.
        cells[k] = cells[k] == ' ' ? ch : max(cells[k], ch)
    end
    return cells
end

# La note d'un événement quand elle s'écrit en chiffres (`n("0 3 7")`), ou rien.
function _note_digits(value)
    value isa AbstractDict || return nothing
    for k in (:n, :note)
        haskey(value, k) || continue
        v = _resolve_value(value[k])
        (v isa Real && isinteger(v) && abs(v) < 1000) && return string(Int(v))
    end
    return nothing
end

"""
    _lane_digits!(cells, events, cycle) -> cells

Quand toutes les notes d'un cycle s'écrivent en chiffres, la piste les
montre telles qu'on les a écrites (`0···3·7·`) plutôt qu'en hauteurs de
bloc : on lit le pattern, pas une silhouette. Un nombre à deux chiffres
déborde sur la cellule suivante si elle est libre.
"""
function _lane_digits!(cells::Vector{Char}, events, cycle::Integer)
    labels = [_note_digits(ev.value) for ev in events]
    (isempty(labels) || any(isnothing, labels)) && return cells
    width = length(cells)
    starts = Set(clamp(floor(Int, (Float64(ev.start) - cycle) * width) + 1, 1, width) for ev in events if 0 <= Float64(ev.start) - cycle < 1)
    for (ev, lab) in zip(events, labels)
        pos = Float64(ev.start) - cycle
        0 <= pos < 1 || continue
        k = clamp(floor(Int, pos * width) + 1, 1, width)
        for (j, ch) in enumerate(lab)
            kk = k + j - 1
            (kk > width || (j > 1 && kk in starts)) && break
            cells[kk] = ch
        end
    end
    return cells
end

function _lane_for(m::RessacApp, slot::Symbol, pat, cyc::Int, width::Int)
    key = (cyc, objectid(pat), width)
    c = get(m.lane_cache, slot, nothing)
    (c !== nothing && c[1] == key) && return c[2]
    cells = try
        evs = Base.invokelatest(pat, Rational{Int64}(cyc), Rational{Int64}(cyc + 1))
        _lane_digits!(_lane_cells(evs, cyc, width), evs, cyc)
    catch
        fill(' ', width)
    end
    m.lane_cache[slot] = (key, cells)
    return cells
end

# ── Les couleurs ─────────────────────────────────────────────────────

_rgb(c::TK.ColorRGB) = c
_rgb(c::TK.AbstractColor) = TK.to_rgb(c)

# Le fond d'une cellule, sans toucher à son caractère ni à sa couleur.
function _tint_cell!(buf::TK.Buffer, x::Int, y::Int, bg::TK.ColorRGB)
    TK.in_bounds(buf, x, y) || return
    i = TK.buf_index(buf, x, y)
    c = buf.content[i]; s = c.style
    buf.content[i] = TK.Cell(c.char, TK.Style(s.fg, bg, s.bold, s.dim, s.italic, s.underline,
                                             s.strikethrough, s.hyperlink), c.suffix)
    return
end

# Combien une ligne est allumée, de 0 à 1 : pleine au coup, éteinte un quart
# de seconde après. `fired` est l'instant du dernier coup envoyé.
const _GLOW_SECONDS = 0.25
_glow(now::Float64, fired::Float64) = now < fired ? 0.0 : clamp(1 - (now - fired) / _GLOW_SECONDS, 0.0, 1.0)

# ── Le rendu ─────────────────────────────────────────────────────────

const _GRID_LABEL = 4      # « d1 » et ses marges, à gauche de la piste

"""
    _grid_zone(body) -> (x0, largeur) | nothing

Où se dessine la grille du cycle dans le texte `body` : ses `largeur`
cellules finissent au bord droit, précédées du nom du slot et d'un filet.
Large si le texte garde de quoi s'écrire, étroite sinon, absente quand la
pane est trop petite.
"""
function _grid_zone(body::TK.Rect)
    for w in (_LANE_WIDE, _LANE_NARROW)
        body.width - (w + _GRID_LABEL + 1) >= 44 && return (body.x + body.width - w, w)
    end
    return nothing
end

"""
    _render_slot_marks!(m, pane, rect, buf)

Dessine signes, fonds, grille et erreurs par-dessus la pane des patterns
(`rect` est le rectangle de la pane, bande de titre comprise). Sans effet
sur une pane qui ne montre pas le texte des patterns.
"""
function _render_slot_marks!(m::RessacApp, pane::EditorPane, rect::TK.Rect, buf::TK.Buffer)
    1 <= pane.current_tab <= length(pane.tabs) || return
    ed = pane.tabs[pane.current_tab].code_editor
    ed === _patterns_editor(m) || return
    body = _editor_text_rect(pane, rect)
    signs_x = body.x - _SIGN_COLS
    signs_x > rect.x || return                       # pas de colonne des signes (pane trop étroite)
    p = _ui()
    lines = _slot_lines(m)
    set = _mark_set()
    now = time()
    fired = fired_snapshot(m.scheduler)
    sched = m.scheduler
    cyc = _cycle_index(sched)
    phase = sched.t_start > 0 ? mod(_current_cycle(sched), 1.0) : 0.0
    playing = Dict{Symbol,Pattern}(pattern_snapshot(sched))
    gw = ed.show_line_numbers ? ndigits(max(length(ed.lines), 1)) + 1 : 0
    right = body.x + body.width - 1
    bottom = body.y + body.height - 1
    calm = m.calm || ressac_config().calm
    cursor_y = (ed.focused && m.modal === :none) ? body.y + (ed.cursor_row - 1 - ed.scroll_offset) : 0
    text_end(row) = body.x + gw + max(length(ed.lines[row]) - ed.h_scroll, 0)   # première colonne libre après le texte

    zone = m.lanes ? _grid_zone(body) : nothing
    x0, w = zone === nothing ? (right + 1, 0) : zone
    xr = x0 - _GRID_LABEL - 1                          # le filet de la grille
    beat = max(w ÷ 4, 1)
    zebra(k) = iseven(k ÷ beat) ? p.s1 : TK.NoColor()
    # La ligne du curseur garde son texte entier : si elle arrive sur la
    # grille, c'est la grille qui s'efface sur cette ligne.
    cursor_long = zone !== nothing && body.y <= cursor_y <= bottom &&
                  1 <= ed.cursor_row <= length(ed.lines) && text_end(ed.cursor_row) > xr - 1

    # ── Le fond de la grille : un temps sur deux, sur toute la hauteur ──
    if zone !== nothing
        for y in body.y:bottom
            (cursor_long && y == cursor_y) && continue
            _clear_rect!(buf, TK.Rect(xr, y, right - xr + 1, 1))
            TK.set_char!(buf, xr, y, '│', TK.Style(fg = p.x))
            for k in 0:(w - 1)
                iseven(k ÷ beat) && TK.set_char!(buf, x0 + k, y, ' ', TK.Style(bg = p.s1))
            end
        end
        # L'en-tête, dans la bande de titre de la pane : SL 1 · · · 2 · · ·
        hy = rect.y
        TK.set_char!(buf, xr, hy, '│', TK.Style(fg = p.x, bg = p.s2))
        TK.set_string!(buf, xr + 1, hy, " SL ", TK.Style(fg = p.n, bg = p.s2))
        step = beat >= 12 ? 3 : 2
        for k in 0:(w - 1)
            ch, sty = k % beat == 0 ? (Char('1' + k ÷ beat), TK.Style(fg = p.tx, bg = p.s2, bold = true)) :
                      k % step == 0 ? ('·', TK.Style(fg = p.n, bg = p.s2)) : (' ', TK.Style(bg = p.s2))
            TK.set_char!(buf, x0 + k, hy, ch, sty)
        end
    end

    # ── La ligne du curseur ──────────────────────────────────────────
    cursor_bg = _ui_tint(p.o, 0.15)
    # En mode visuel, la sélection tient lieu de ligne du curseur : deux fonds
    # de même valeur l'un sur l'autre ne se distinguent pas.
    if body.y <= cursor_y <= bottom && ed.mode === :normal && !m.visual_active
        cx = _cursor_cell_x(ed, body)
        for x in signs_x:right
            x == cx || _tint_cell!(buf, x, cursor_y, cursor_bg)     # la cellule du curseur garde son orange
        end
    end

    for l in lines
        y0 = body.y + (l.row - 1 - ed.scroll_offset)
        on_cursor = cursor_y != 0 && l.row <= ed.cursor_row <= l.last_row
        # Le fond du bloc : rouge pour une erreur, vert pour un texte modifié,
        # un éclat au coup pour une ligne qui joue.
        glow = _glow(now, get(fired, l.slot, 0.0))
        tint = l.state === :error ? _ui_tint(p.r, 0.17) :
               l.state === :modified ? _ui_tint(p.g, 0.11) :
               (l.state === :playing && !l.held && !calm && glow > 0) ? TK.color_lerp(p.bg, p.tx, 0.10 * glow) : nothing
        if tint !== nothing && !on_cursor
            whole = l.state !== :playing              # l'éclat ne couvre que le texte : la grille garde ses temps
            for r in l.row:l.last_row
                y = body.y + (r - 1 - ed.scroll_offset)
                body.y <= y <= bottom || continue
                for x in signs_x:(whole || zone === nothing ? right : xr - 1)
                    _tint_cell!(buf, x, y, tint)
                end
            end
        end
        body.y <= y0 <= bottom || continue
        # Le signe.
        color = on_cursor ? p.o : l.state === :error ? p.r : l.state === :muted ? p.n : p.g
        ch = _mark_char(l, set)
        ch === nothing || TK.set_char!(buf, signs_x, y0, ch,
                                       TK.Style(fg = color, bg = buf.content[TK.buf_index(buf, signs_x, y0)].style.bg,
                                                bold = l.state !== :muted))
        rowbg = on_cursor ? cursor_bg : (tint !== nothing && l.state !== :playing) ? tint : nothing
        if zone === nothing
            # Pas de grille : l'erreur s'écrit au bout de la ligne.
            if l.error !== nothing
                x = text_end(l.row) + 2
                room = right - x + 1
                room >= 12 && TK.set_string!(buf, x, y0, _fit(_error_text(l.error), room),
                                             TK.Style(fg = p.r, bg = rowbg === nothing ? TK.NoColor() : rowbg))
            end
            continue
        end
        (cursor_long && y0 == cursor_y) && continue
        cellbg(k) = rowbg === nothing ? zebra(k) : rowbg
        labelbg = rowbg === nothing ? TK.NoColor() : rowbg
        # Le nom de la piste.
        TK.set_string!(buf, xr + 1, y0, rpad(" " * String(l.slot), _GRID_LABEL), TK.Style(fg = color, bg = labelbg, bold = on_cursor))
        # L'erreur prend la place de la piste.
        if l.error !== nothing
            TK.set_string!(buf, x0, y0, rpad(_fit(_error_text(l.error), w), w), TK.Style(fg = p.r, bg = labelbg))
            continue
        end
        pat = get(playing, l.slot, nothing)
        (pat === nothing || !(l.state in (:playing, :modified, :muted))) && continue
        cells = _lane_for(m, l.slot, pat, cyc, w)
        hit = on_cursor ? p.o : l.state === :muted ? TK.color_lerp(p.x, p.n, 0.5) : p.d
        for k in 0:(w - 1)
            ch, fg, bold = l.held ? ('━', hit, false) :
                           cells[k + 1] != ' ' ? (cells[k + 1], hit, true) : ('·', p.x, false)
            TK.set_char!(buf, x0 + k, y0, ch, TK.Style(fg = fg, bg = cellbg(k), bold = bold))
        end
    end

    # ── La tête de lecture : une colonne qui traverse toute la grille ──
    if zone !== nothing && sched.t_start > 0
        hx = x0 + clamp(floor(Int, phase * w), 0, w - 1)
        for y in body.y:bottom
            (cursor_long && y == cursor_y) && continue
            cur = buf.content[TK.buf_index(buf, hx, y)].style.bg
            _tint_cell!(buf, hx, y, TK.color_lerp(cur isa TK.NoColor ? p.bg : _ui_rgb(cur), p.o, 0.32))
        end
    end
    return nothing
end

# « ← cause · ce qui continue »
_error_text(e::SlotError) =
    "← " * e.message * (e.kept ? " · l'ancien joue toujours" : " · rien ne jouait")

_fit(s::AbstractString, room::Int) = textwidth(s) <= room ? String(s) : first(s, max(room - 1, 0)) * "…"

# La colonne d'écran du curseur de `ed`, dont le texte (numéros compris)
# occupe `body`. Teinter la ligne du curseur ne doit pas repeindre cette
# cellule : son fond orange EST le curseur.
function _cursor_cell_x(ed::TK.CodeEditor, body::TK.Rect)
    gw = ed.show_line_numbers ? ndigits(max(length(ed.lines), 1)) + 1 : 0
    return body.x + gw + ed.cursor_col - ed.h_scroll
end

# La ligne du curseur d'un éditeur qui n'est pas celui des patterns (le
# texte d'un son) : le même fond orangé, pour que l'œil la retrouve.
function _render_cursor_line!(m::RessacApp, pane::EditorPane, rect::TK.Rect, buf::TK.Buffer)
    1 <= pane.current_tab <= length(pane.tabs) || return
    ed = pane.tabs[pane.current_tab].code_editor
    (ed === _patterns_editor(m) || !ed.focused || ed.mode !== :normal || m.modal !== :none || m.visual_active) && return
    body = _editor_text_rect(pane, rect)
    y = body.y + (ed.cursor_row - 1 - ed.scroll_offset)
    body.y <= y < body.y + body.height || return
    bg = _ui_tint(_ui().o, 0.15)
    cx = _cursor_cell_x(ed, body)
    for x in body.x:(body.x + body.width - 1)
        x == cx || _tint_cell!(buf, x, y, bg)
    end
    return
end

# ── La réglette ──────────────────────────────────────────────────────
# Le curseur est sur un nombre : c'est un knob (`+ - * /`, la molette). Au
# bout de sa ligne, la réglette dit lequel — son nom, ses bornes, où il en
# est. Un affichage, rien de plus : il n'y a pas de pane de knobs.

# Les bornes des contrôles de pattern les plus courants : (bas, haut).
const _PATTERN_KNOB_RANGES = Dict{String,Tuple{Float64,Float64}}(
    "gain" => (0.0, 1.5), "pan" => (0.0, 1.0), "lpf" => (20.0, 20000.0), "cutoff" => (20.0, 20000.0),
    "hpf" => (20.0, 20000.0), "hcutoff" => (20.0, 20000.0), "resonance" => (0.0, 1.0),
    "room" => (0.0, 1.0), "size" => (0.0, 1.0), "delay" => (0.0, 1.0), "delaytime" => (0.0, 2.0),
    "delayfeedback" => (0.0, 1.0), "shape" => (0.0, 1.0), "crush" => (1.0, 16.0), "coarse" => (1.0, 64.0),
    "speed" => (-4.0, 4.0), "legato" => (0.0, 4.0), "sustain" => (0.0, 8.0), "attack" => (0.0, 2.0),
    "release" => (0.0, 8.0), "fast" => (0.0, 16.0), "slow" => (0.0, 16.0), "degradeBy" => (0.0, 1.0),
    "n" => (-24.0, 24.0), "note" => (-24.0, 24.0), "octave" => (1.0, 8.0), "squiz" => (1.0, 8.0),
)

"""
    _knob_at(m, ed) -> (nom, bas, haut, valeur) | nothing

Le knob sous le curseur de `ed` : un nombre dont on connaît la place — un
réglage d'UGen dans un son (catalogue), un contrôle dans un pattern.
"""
function _knob_at(m::RessacApp, ed::TK.CodeEditor)
    hit = _number_at(ed, ed.cursor_row, ed.cursor_col)
    hit === nothing && return nothing
    v = tryparse(Float64, hit[3])
    v === nothing && return nothing
    chars = ed.lines[ed.cursor_row]
    sl = _slot_at(chars, hit[1] + 1)
    sl !== nothing && sl.lo < sl.hi && return (String(sl.name), Float64(sl.lo), Float64(sl.hi), v)
    fn = _enclosing_call(chars, hit[1])
    r = get(_PATTERN_KNOB_RANGES, fn, nothing)
    r === nothing && return nothing
    return (fn, r[1], r[2], v)
end

const _KNOB_WIDTH = 12

# Où est `v` entre `lo` et `hi`, de 0 à 1 — en log quand la plage est une
# plage de fréquences (plus de deux décades, bas positif).
function _knob_position(v::Float64, lo::Float64, hi::Float64)
    if lo > 0 && hi / lo >= 100 && v > 0
        return clamp(log(v / lo) / log(hi / lo), 0.0, 1.0)
    end
    return clamp((v - lo) / (hi - lo), 0.0, 1.0)
end

"""
    _knob_text(nom, bas, haut, valeur) -> String

« rq  0.05 ━━●━━━━━━━━━ 1 »
"""
function _knob_text(name::AbstractString, lo::Float64, hi::Float64, v::Float64)
    k = clamp(round(Int, _knob_position(v, lo, hi) * (_KNOB_WIDTH - 1)), 0, _KNOB_WIDTH - 1)
    bar = repeat('━', k) * "●" * repeat('━', _KNOB_WIDTH - 1 - k)
    return "$name  $(_atelier_num(lo)) $bar $(_atelier_num(hi))"
end

"""
    _render_knob!(m, pane, rect, buf)

Dessine la réglette au bout de la ligne du curseur, dans la pane qui a le
clavier, en mode normal. Elle prend la place de la piste sur cette ligne.
"""
function _render_knob!(m::RessacApp, pane::EditorPane, rect::TK.Rect, buf::TK.Buffer)
    1 <= pane.current_tab <= length(pane.tabs) || return
    ed = pane.tabs[pane.current_tab].code_editor
    (ed.focused && ed.mode === :normal && m.modal === :none) || return
    knob = _knob_at(m, ed)
    knob === nothing && return
    body = _editor_text_rect(pane, rect)
    y = body.y + (ed.cursor_row - 1 - ed.scroll_offset)
    body.y <= y < body.y + body.height || return
    text = _knob_text(knob...)
    gw = ed.show_line_numbers ? ndigits(max(length(ed.lines), 1)) + 1 : 0
    text_end = body.x + gw + length(ed.lines[ed.cursor_row]) - ed.h_scroll
    right = body.x + body.width - 1
    w = textwidth(text)
    x = right - w + 1
    x >= text_end + 2 || return                       # pas la place : la ligne passe avant
    for xx in (x - 1):right                           # efface la piste dessous
        TK.set_char!(buf, xx, y, ' ', TK.Style())
    end
    TK.set_string!(buf, x, y, text, TK.tstyle(:accent, bold = true))
    return
end
