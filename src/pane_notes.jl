# src/pane_notes.jl
# Visualiseur de notes — ce qui joue, en train de défiler. Le temps va
# de gauche à droite, la hauteur monte, une couleur par slot. Les sons
# sans hauteur (percussions) ont leurs propres couloirs en bas.
#
# La pane ne garde pas d'historique : elle interroge les patterns du
# scheduler autour de l'instant courant. Ce qu'on voit à gauche vient
# d'être joué, ce qu'on voit à droite va l'être — et éditer un slot se
# voit immédiatement, y compris dans le futur proche.

mutable struct NotesPane <: PaneImpl
    span::Rational{Int64}     # largeur de la fenêtre, en cycles
    perc_rows::Int            # hauteur réservée aux sons sans hauteur
end

_notes_pane_ctor(args::AbstractDict) =
    NotesPane(Rational{Int64}(get(args, "span_num", 2), max(1, get(args, "span_den", 1))),
              clamp(Int(get(args, "perc_rows", 4)), 1, 12))

# Une couleur stable par slot : d1 bleu, d2 vert, d3 orange…
const _NOTE_COLORS = (75, 114, 215, 175, 79, 221, 141, 209, 45, 180, 111, 168)
_slot_color(slot::Symbol) = begin
    s = String(slot)
    n = length(s) >= 2 ? something(tryparse(Int, SubString(s, 2)), 1) : 1
    TK.Color256(_NOTE_COLORS[mod1(n, length(_NOTE_COLORS))])
end

"""
    _note_row(value) -> Union{Nothing,Float64}

La hauteur d'un événement, en note MIDI : `note` / `n` sont des
demi-tons depuis do 5 (MIDI 60), `freq` est converti. Rien si
l'événement n'a pas de hauteur — c'est une percussion.
"""
function _note_row(value)
    value isa AbstractDict || return nothing
    for k in (:note, :n)
        haskey(value, k) || continue
        v = _resolve_value(value[k])
        v isa Real && return 60.0 + float(v)
    end
    if haskey(value, :freq)
        v = _resolve_value(value[:freq])
        v isa Real && v > 0 && return hz_to_midi(v)
    end
    return nothing
end

# Le nom du son d'un événement, pour les couloirs de percussion.
_note_name(value::AbstractDict) = String(get(value, :s, :?))
_note_name(value) = String(value)

"""
    _notes_events(m, win_a, win_b) -> Vector

Les événements de tous les slots sur la fenêtre demandée, avec leur
slot, leurs bornes, leur hauteur éventuelle et leur nom.
"""
function _notes_events(sched, win_a::Rational, win_b::Rational)
    out = Tuple{Symbol,Rational{Int64},Rational{Int64},Union{Nothing,Float64},String}[]
    sched === nothing && return out
    for (slot, pat) in sched.patterns
        for cyc in floor(Int, win_a):ceil(Int, win_b)
            evs = try
                Base.invokelatest(pat, Rational{Int64}(cyc), Rational{Int64}(cyc + 1))
            catch
                continue
            end
            for ev in evs
                ev.start < win_a && continue
                ev.start > win_b && continue
                push!(out, (slot, ev.start, ev.stop, _note_row(ev.value), _note_name(ev.value)))
            end
        end
    end
    return out
end

function render!(p::NotesPane, area, buf)
    rect = TK.Rect(area.x, area.y, area.width, area.height)
    sched = _LIVE_SCHEDULER[]
    _render_pane_block_simple!(rect, "NOTES · $(p.span) cycle$(p.span == 1 ? "" : "s")", buf)
    inner = _inner_rect_simple(rect)
    (inner.height < 3 || inner.width < 10) && return nothing
    if sched === nothing || isempty(sched.patterns)
        TK.set_string!(buf, inner.x, inner.y,
                       first("Rien ne joue. Évalue un @dN et les notes défilent ici.", inner.width),
                       TK.tstyle(:text_dim))
        return nothing
    end
    now = Rational{Int64}(round(Int, ((time() - sched.t_start) * sched.cps) * 480), 480)
    win_a = now - p.span * 3 // 4
    win_b = now + p.span * 1 // 4
    evs = _notes_events(sched, win_a, win_b)

    # ── Légende : un slot par couleur, sur la première ligne ────────
    slots = sort!(unique(e[1] for e in evs); by = string)
    x = inner.x
    for s in slots
        lbl = String(s) * " "
        x + textwidth(lbl) > inner.x + inner.width && break
        TK.set_string!(buf, x, inner.y, lbl, TK.Style(fg = _slot_color(s), bold = true))
        x += textwidth(lbl)
    end
    grid_y = inner.y + 1
    grid_h = inner.height - 1
    grid_h < 2 && return nothing
    perc_h = min(p.perc_rows, max(1, grid_h ÷ 3))
    pitch_h = grid_h - perc_h - 1                 # -1 pour la ligne de séparation
    w = inner.width

    # ── Zone des hauteurs, échelle automatique ──────────────────────
    rows = Float64[e[4] for e in evs if e[4] !== nothing]
    lo, hi = isempty(rows) ? (60.0, 72.0) : (minimum(rows) - 2, maximum(rows) + 2)
    hi - lo < 6 && (mid = (lo + hi) / 2; lo = mid - 3; hi = mid + 3)
    xcol(t) = inner.x + clamp(round(Int, Float64((t - win_a) / (win_b - win_a)) * (w - 1)), 0, w - 1)
    if pitch_h >= 1
        for (slot, a, b, row, _) in evs
            row === nothing && continue
            ry = grid_y + pitch_h - 1 - clamp(round(Int, (row - lo) / (hi - lo) * (pitch_h - 1)), 0, pitch_h - 1)
            x0 = xcol(a); x1 = max(x0, xcol(min(b, win_b)) - 1)
            sty = TK.Style(fg = _slot_color(slot), bold = true)
            TK.set_string!(buf, x0, ry, "█", sty)
            for xx in (x0 + 1):min(x1, inner.x + w - 1)
                TK.set_string!(buf, xx, ry, "━", TK.Style(fg = _slot_color(slot)))
            end
        end
        # repères d'octave dans la marge
        for mnote in ceil(Int, lo / 12) * 12:12:floor(Int, hi)
            ry = grid_y + pitch_h - 1 - clamp(round(Int, (mnote - lo) / (hi - lo) * (pitch_h - 1)), 0, pitch_h - 1)
            TK.set_string!(buf, inner.x, ry, "·", TK.tstyle(:text_dim))
        end
    end

    # ── Séparation, puis couloirs de percussion ─────────────────────
    sep_y = grid_y + pitch_h
    if pitch_h >= 1 && sep_y < grid_y + grid_h
        TK.set_string!(buf, inner.x, sep_y, "─" ^ w, TK.tstyle(:border))
    end
    names = sort!(unique(e[5] for e in evs if e[4] === nothing))
    for (slot, a, b, row, name) in evs
        row === nothing || continue
        i = findfirst(==(name), names)
        i === nothing && continue
        ry = sep_y + 1 + mod(i - 1, perc_h)
        ry < grid_y + grid_h || continue
        TK.set_string!(buf, xcol(a), ry, "█", TK.Style(fg = _slot_color(slot), bold = true))
    end
    for (i, name) in enumerate(names)
        i > perc_h && break
        ry = sep_y + 1 + i - 1
        ry < grid_y + grid_h || break
        TK.set_string!(buf, inner.x + w - min(w, textwidth(name)), ry,
                       first(name, w), TK.tstyle(:text_dim))
    end

    # ── Tête de lecture ─────────────────────────────────────────────
    xn = xcol(now)
    for y in grid_y:(grid_y + grid_h - 1)
        TK.set_string!(buf, xn, y, "│", TK.tstyle(:accent))
    end
    return nothing
end

handle_key!(p::NotesPane, evt) = evt isa TK.KeyEvent && dispatch!(((:notes, p),), evt)
pane_scope(::NotesPane) = :notes
title(p::NotesPane) = "notes"
serialize(p::NotesPane) = Dict{String,Any}("span_num" => numerator(p.span),
                                           "span_den" => denominator(p.span),
                                           "perc_rows" => p.perc_rows)
register_pane_kind!(:notes, _notes_pane_ctor)

scope!(:notes, "Visualiseur de notes")
bind!(:notes, ["+", "l", "→"], "fenêtre plus large"; short = "plus large", group = :nav, repeat = true,
      action = p -> (p.span = min(p.span * 2, Rational{Int64}(32))))
bind!(:notes, ["-", "h", "←"], "fenêtre plus étroite"; short = "plus étroite", group = :nav, repeat = true,
      action = p -> (p.span = max(p.span // 2, Rational{Int64}(1, 4))))
bind!(:notes, ["j", "↓"], "moins de couloirs de percussion"; group = :nav, hint = false, repeat = true,
      action = p -> (p.perc_rows = max(1, p.perc_rows - 1)))
bind!(:notes, ["k", "↑"], "plus de couloirs de percussion"; group = :nav, hint = false, repeat = true,
      action = p -> (p.perc_rows = min(12, p.perc_rows + 1)))
