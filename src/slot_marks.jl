# src/slot_marks.jl
# Ce que l'écran dit de chaque ligne @dN, sur la ligne elle-même :
#   • un SIGNE dans la colonne de gauche (une note dont la valeur suit la
#     vitesse du pattern, un silence pour un slot muet, un dièse pour un
#     texte modifié, un point d'orgue pour un drone…) ;
#   • le FOND de la ligne, qui s'allume au coup et retombe ;
#   • une PISTE d'un cycle au bout de la ligne ;
#   • l'ERREUR, écrite au bout de la ligne fautive.
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

# La largeur de piste qui tient à droite d'un texte de `text_len` colonnes
# dans une ligne de `width` : large, étroite, ou rien.
function _lane_width(text_len::Integer, width::Integer)
    room = width - text_len - 2
    room >= _LANE_WIDE && return _LANE_WIDE
    room >= _LANE_NARROW && return _LANE_NARROW
    return 0
end

function _lane_for(m::RessacApp, slot::Symbol, pat, cyc::Int, width::Int)
    key = (cyc, objectid(pat), width)
    c = get(m.lane_cache, slot, nothing)
    (c !== nothing && c[1] == key) && return c[2]
    cells = try
        _lane_cells(Base.invokelatest(pat, Rational{Int64}(cyc), Rational{Int64}(cyc + 1)), cyc, width)
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

"""
    _line_tint(line, glow, calm) -> (couleur, force, hachuré) | nothing

Le fond d'une ligne selon son état. `force` est la part de la couleur dans
le mélange avec le fond du thème.
"""
function _line_tint(l::SlotLine, glow::Float64, calm::Bool)
    th = TK.theme()
    l.state === :error && return (_rgb(th.error), 0.22, false)
    l.state === :modified && return (_rgb(_slot_color(l.slot)), 0.16, true)
    l.state === :playing || return nothing
    l.held && return (_rgb(_slot_color(l.slot)), 0.18, false)
    return (_rgb(_slot_color(l.slot)), calm ? 0.10 : 0.08 + 0.26 * glow, false)
end

# ── Le rendu ─────────────────────────────────────────────────────────

"""
    _render_slot_marks!(m, pane, rect, buf)

Dessine signes, fonds, pistes et erreurs par-dessus la pane des patterns
(`rect` est le rectangle de la pane, cadre compris). Sans effet sur une
pane qui ne montre pas le texte des patterns.
"""
function _render_slot_marks!(m::RessacApp, pane::EditorPane, rect::TK.Rect, buf::TK.Buffer)
    1 <= pane.current_tab <= length(pane.tabs) || return
    ed = pane.tabs[pane.current_tab].code_editor
    ed === _patterns_editor(m) || return
    body = _editor_text_rect(pane, rect)
    signs_x = body.x - _SIGN_COLS
    signs_x > rect.x || return                       # pas de colonne des signes (pane trop étroite)
    lines = _slot_lines(m)
    isempty(lines) && return
    set = _mark_set()
    th = TK.theme()
    base = _rgb(th.bg)
    now = time()
    fired = fired_snapshot(m.scheduler)
    sched = m.scheduler
    cyc = _cycle_index(sched)
    phase = sched.t_start > 0 ? mod(_current_cycle(sched), 1.0) : 0.0
    playing = Dict{Symbol,Pattern}(pattern_snapshot(sched))
    gw = ed.show_line_numbers ? ndigits(max(length(ed.lines), 1)) + 1 : 0
    right = body.x + body.width - 1
    for l in lines
        y0 = body.y + (l.row - 1 - ed.scroll_offset)
        # Le fond, sur toutes les lignes du bloc.
        tint = _line_tint(l, _glow(now, get(fired, l.slot, 0.0)), m.calm || ressac_config().calm)
        if tint !== nothing
            (color, force, hatched) = tint
            bg = TK.color_lerp(base, color, force)
            for r in l.row:l.last_row
                y = body.y + (r - 1 - ed.scroll_offset)
                body.y <= y < body.y + body.height || continue
                for x in signs_x:right
                    (hatched && iseven((x - signs_x) ÷ 2)) && continue
                    _tint_cell!(buf, x, y, bg)
                end
            end
        end
        body.y <= y0 < body.y + body.height || continue
        # Le signe.
        ch = _mark_char(l, set)
        if ch !== nothing
            fg = l.state === :error ? th.error :
                 l.state === :muted ? th.text_dim : _slot_color(l.slot)
            TK.set_char!(buf, signs_x, y0, ch, TK.Style(fg = fg, bold = l.state !== :muted))
        end
        text_len = gw + length(ed.lines[l.row]) - ed.h_scroll
        # L'erreur prend la place de la piste.
        if l.error !== nothing
            x = body.x + max(text_len, 0) + 2
            room = right - x + 1
            room >= 12 && TK.set_string!(buf, x, y0, _fit(_error_text(l.error), room), TK.tstyle(:error))
            continue
        end
        m.lanes || continue
        (l.state === :playing || l.state === :modified) || continue
        w = _lane_width(max(text_len, 0), body.width)
        w == 0 && continue
        _render_lane!(buf, right - w + 1, y0, w, l, _lane_for(m, l.slot, get(playing, l.slot, nothing), cyc, w), phase)
    end
    return nothing
end

# « ← cause · ce qui continue »
_error_text(e::SlotError) =
    "← " * e.message * (e.kept ? " · l'ancien joue toujours" : " · rien ne jouait")

_fit(s::AbstractString, room::Int) = textwidth(s) <= room ? String(s) : first(s, max(room - 1, 0)) * "…"

function _render_lane!(buf::TK.Buffer, x0::Int, y::Int, w::Int, l::SlotLine, cells::Vector{Char}, phase::Float64)
    th = TK.theme()
    color = _slot_color(l.slot)
    dim = TK.Style(fg = th.border)
    beat = w ÷ 4
    head = clamp(floor(Int, phase * w), 0, w - 1)
    for k in 0:(w - 1)
        ch, sty = if l.held
            ('━', TK.Style(fg = color))                # un drone : une bande, pas des coups
        elseif cells[k + 1] != ' '
            (cells[k + 1], TK.Style(fg = color, bold = true))
        else
            (k % beat == 0 ? '┆' : '·', dim)            # la grille : un trait par temps
        end
        TK.set_char!(buf, x0 + k, y, ch, sty)
    end
    # La tête de lecture : une colonne qui traverse toutes les pistes.
    _tint_cell!(buf, x0 + head, y, TK.color_lerp(_rgb(th.bg), _rgb(th.accent), 0.45))
    return
end
