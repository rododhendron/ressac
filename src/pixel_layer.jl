# src/pixel_layer.jl
# La grille du cycle en vrais pixels, DERRIÈRE le texte.
#
# Dans un terminal qui parle le protocole graphique de kitty, la zone de
# droite du texte n'est plus dessinée en caractères : c'est une image, posée
# sous les cellules. Le texte passe par-dessus ; une ligne longue ne chasse
# plus sa piste.
#
#   • les temps (un sur deux, sur toute la hauteur) ;
#   • une piste par slot, sur sa ligne : chaque note à sa place et à sa
#     longueur, et à sa HAUTEUR dans la ligne quand le pattern en a ;
#   • la tête de lecture, qui glisse au pixel ;
#   • en bas, en grand : le visuel que chaque slot demande dans son texte
#     (`|> pianoroll()`, `|> pitchwheel()`), et le rouleau du slot du curseur.
#
# Comment ça tient : l'image a un z si bas que kitty la dessine sous les
# cellules qui ont un fond. La dernière passe du rendu laisse donc SANS fond
# les cellules de la zone qui n'en avaient pas (`_PIXEL_HOLE`) — l'image s'y
# voit — et tout ce qui flotte (un menu, une complétion, une sélection) la
# cache naturellement, puisque ça a un fond.
#
# `_render_slot_marks!` remplit la scène ; `_pixel_layer!` la peint après le
# rendu des cellules. Sans protocole graphique (ou `:pixels` coupé), rien de
# tout ça : la grille en caractères reste.

# Les types de la scène sont dans pixel_types.jl (le modèle de l'app les porte).

# La zone que l'image occupe à cette image-ci (lue par `_ui_finish!`).
const _PIXEL_HOLE = Ref{Union{Nothing,TK.Rect}}(nothing)
# Forcer l'état en test : `true` / `false`, ou `nothing` pour demander au terminal.
const _PIXELS_FORCE = Ref{Union{Nothing,Bool}}(nothing)
# Sous les cellules qui ont un fond (voir la doc du protocole de kitty).
const _PIXEL_Z = -1_073_741_825

"La grille se dessine-t-elle en pixels ?"
function _pixels_on(m::RessacApp)
    (m.pixels && ressac_config().pixels) || return false
    f = _PIXELS_FORCE[]
    return f === nothing ? TK.graphics_protocol() == TK.gfx_kitty : f
end

# ── Les notes d'un slot ──────────────────────────────────────────────

"""
    _pixel_notes(m, slot, pattern, cycle) -> Vector{PixelNote}

Les notes du cycle, mémorisées par (cycle, pattern).
"""
function _pixel_notes(m::RessacApp, slot::Symbol, pat, cyc::Int)
    key = (cyc, objectid(pat))
    c = get(m.pixel_cache, slot, nothing)
    (c !== nothing && c[1] == key) && return c[2]
    notes = PixelNote[]
    try
        for ev in preview_query(pat, cyc, cyc + 1)
            a = Float64(ev.start) - cyc
            0 <= a < 1 || continue
            push!(notes, (a, min(Float64(ev.stop) - cyc, 1.0), _note_row(ev.value)))
        end
    catch
    end
    m.pixel_cache[slot] = (key, notes)
    return notes
end

# Le visuel qu'un slot demande dans son texte (ce qui joue), ou rien.
const _VIEW_RX = r"\b(pianoroll|pitchwheel)\s*\("
function _slot_view(m::RessacApp, slot::Symbol)
    src = get(m.slot_evaluated, slot, nothing)
    src === nothing && return nothing
    mt = match(_VIEW_RX, src)
    return mt === nothing ? nothing : Symbol(mt.captures[1])
end

# ── La toile ─────────────────────────────────────────────────────────

struct PixelCanvas
    data::Vector{UInt8}      # RGBA, ligne par ligne
    w::Int
    h::Int
end

const _PIXEL_BUFFER = UInt8[]

function _canvas(w::Int, h::Int, bg::TK.ColorRGB)
    resize!(_PIXEL_BUFFER, w * h * 4)
    @inbounds for i in 0:(w * h - 1)
        _PIXEL_BUFFER[4i + 1] = bg.r; _PIXEL_BUFFER[4i + 2] = bg.g
        _PIXEL_BUFFER[4i + 3] = bg.b; _PIXEL_BUFFER[4i + 4] = 0xff
    end
    return PixelCanvas(_PIXEL_BUFFER, w, h)
end

# Un rectangle (pixels, bords compris), mêlé à ce qui est dessous.
function _px_rect!(c::PixelCanvas, x0::Int, y0::Int, x1::Int, y1::Int, col::TK.ColorRGB, alpha::Float64 = 1.0)
    x0 = max(x0, 0); y0 = max(y0, 0); x1 = min(x1, c.w - 1); y1 = min(y1, c.h - 1)
    (x0 > x1 || y0 > y1 || alpha <= 0) && return
    a = clamp(alpha, 0.0, 1.0)
    @inbounds for y in y0:y1, x in x0:x1
        i = 4 * (y * c.w + x)
        c.data[i + 1] = round(UInt8, c.data[i + 1] + (col.r - Float64(c.data[i + 1])) * a)
        c.data[i + 2] = round(UInt8, c.data[i + 2] + (col.g - Float64(c.data[i + 2])) * a)
        c.data[i + 3] = round(UInt8, c.data[i + 3] + (col.b - Float64(c.data[i + 3])) * a)
    end
    return
end

_px_at(c::PixelCanvas, x::Int, y::Int) =
    (i = 4 * (y * c.w + x); (c.data[i + 1], c.data[i + 2], c.data[i + 3]))

# ── La peinture ──────────────────────────────────────────────────────

# Un trait (pixels), et un disque.
function _px_line!(c::PixelCanvas, x0::Real, y0::Real, x1::Real, y1::Real, col::TK.ColorRGB, alpha::Float64 = 1.0)
    n = max(ceil(Int, max(abs(x1 - x0), abs(y1 - y0))), 1)
    for i in 0:n
        t = i / n
        x = round(Int, x0 + (x1 - x0) * t); y = round(Int, y0 + (y1 - y0) * t)
        _px_rect!(c, x, y, x, y, col, alpha)
    end
    return
end

function _px_disc!(c::PixelCanvas, cx::Real, cy::Real, r::Real, col::TK.ColorRGB, alpha::Float64 = 1.0)
    for y in floor(Int, cy - r):ceil(Int, cy + r), x in floor(Int, cx - r):ceil(Int, cx + r)
        (x - cx)^2 + (y - cy)^2 <= r^2 && _px_rect!(c, x, y, x, y, col, alpha)
    end
    return
end

"""
    _panel_layout(scene) -> Vector{Tuple{Int,Int}}

Où se posent les visuels en grand : (première ligne, nombre de lignes) pour
chaque panneau, en cellules relatives à la zone, empilés au bas de la zone
sous la dernière piste. Moins de panneaux que demandé quand la place
manque (quatre lignes au moins chacun).
"""
function _panel_layout(sc::PixelScene)
    isempty(sc.panels) && return Tuple{Int,Int}[]
    last_lane = isempty(sc.lanes) ? -1 : maximum(l.row - sc.y for l in sc.lanes)
    free = sc.h - (last_lane + 2)
    n = min(length(sc.panels), free ÷ 4)
    n <= 0 && return Tuple{Int,Int}[]
    each = min(8, free ÷ n)
    top = sc.h - n * each
    return [(top + (k - 1) * each, each) for k in 1:n]
end

# Le rouleau : une barre par note, à sa hauteur et à sa longueur.
function _paint_roll!(c::PixelCanvas, pn::PixelPanel, y0::Int, hh::Int, ch::Int, phase::Float64)
    p = _ui()
    W = c.w
    _px_rect!(c, 0, y0, W - 1, y0, p.x)                          # un filet au-dessus
    pitched = [n for n in pn.notes if n[3] !== nothing]
    isempty(pitched) && return
    lo, hi = extrema(n[3] for n in pitched)
    lo -= 1; hi += 1
    step = (hh - 2) / (hi - lo + 1)                              # la hauteur d'un demi-ton
    for s in ceil(Int, lo):floor(Int, hi)                        # les do : un repère
        mod(s, 12) == 0 || continue
        yy = y0 + hh - round(Int, (s - lo + 0.5) * step)
        _px_rect!(c, 0, yy, W - 1, yy, p.x, 0.7)
    end
    bar = clamp(round(Int, step) - 1, 3, ch)
    green = TK.color_lerp(p.bg, p.g, 0.75)
    for n in pitched
        x0 = floor(Int, n[1] * W)
        x1 = max(x0 + 2, floor(Int, n[2] * W) - 3)
        yy = y0 + hh - round(Int, (n[3] - lo + 0.5) * step)
        on = phase >= 0 && n[1] <= phase < n[2]
        _px_rect!(c, x0, yy - bar ÷ 2, x1, yy + (bar - 1) ÷ 2, on ? p.o : green)
    end
    return
end

# La roue : douze heures, le do en haut ; les notes du cycle marquées,
# celles qui sonnent allumées et reliées.
function _paint_wheel!(c::PixelCanvas, pn::PixelPanel, y0::Int, hh::Int, phase::Float64)
    p = _ui()
    W = c.w
    _px_rect!(c, 0, y0, W - 1, y0, p.x)
    cx = W / 2; cy = y0 + hh / 2
    r = min(W, hh) / 2 - 5
    r < 8 && return
    for a in 0:2:359                                             # le cercle
        _px_rect!(c, round(Int, cx + r * cosd(a)), round(Int, cy + r * sind(a)),
                  round(Int, cx + r * cosd(a)), round(Int, cy + r * sind(a)), p.x)
    end
    at(k) = (cx + r * cosd(-90 + 30k), cy + r * sind(-90 + 30k))
    for k in 0:11                                                # les douze heures
        (x, y) = at(k)
        _px_disc!(c, x, y, k == 0 ? 2.0 : 1.2, p.n)
    end
    green = TK.color_lerp(p.bg, p.g, 0.75)
    classes(ns) = unique!(sort!([mod(round(Int, n[3]), 12) for n in ns if n[3] !== nothing]))
    for k in classes(pn.notes)
        (x, y) = at(k); _px_disc!(c, x, y, 3.0, green)
    end
    now = classes([n for n in pn.notes if phase >= 0 && n[1] <= phase < n[2]])
    if length(now) == 1
        (x, y) = at(now[1]); _px_line!(c, cx, cy, x, y, p.o)
    end
    for i in eachindex(now)                                      # l'accord : son polygone
        length(now) > 1 || break
        (xa, ya) = at(now[i]); (xb, yb) = at(now[mod1(i + 1, length(now))])
        _px_line!(c, xa, ya, xb, yb, p.o)
    end
    for k in now
        (x, y) = at(k); _px_disc!(c, x, y, 4.0, p.o)
    end
    return
end

"""
    _paint_scene(scene, cw, ch) -> PixelCanvas

Peint la scène : `cw` × `ch` pixels par cellule. Pure (aucun terminal).
"""
function _paint_scene(sc::PixelScene, cw::Int, ch::Int)
    p = _ui()
    W = sc.w * cw; H = sc.h * ch
    c = _canvas(W, H, p.bg)
    # Les temps : un sur deux.
    for b in (0, 2)
        _px_rect!(c, b * W ÷ 4, 0, (b + 1) * W ÷ 4 - 1, H - 1, p.s1)
    end
    # La ligne du curseur, du même orangé que côté texte.
    if sc.y <= sc.cursor_row < sc.y + sc.h
        y = (sc.cursor_row - sc.y) * ch
        _px_rect!(c, 0, y, W - 1, y + ch - 1, p.o, 0.15)
    end
    sounding(n) = sc.phase >= 0 && n[1] <= sc.phase < n[2]
    for l in sc.lanes
        (sc.y <= l.row < sc.y + sc.h) || continue
        y = (l.row - sc.y) * ch
        base = l.cursor ? p.o : l.state === :muted ? p.x : p.d
        # Le fil de la piste.
        _px_rect!(c, 0, y + ch ÷ 2, W - 1, y + ch ÷ 2, p.x, 0.6)
        if l.held
            _px_rect!(c, 0, y + ch ÷ 2 - 1, W - 1, y + ch ÷ 2 + 1, base)
            continue
        end
        pitches = Float64[n[3] for n in l.notes if n[3] !== nothing]
        lo, hi = isempty(pitches) ? (0.0, 0.0) : extrema(pitches)
        for n in l.notes
            x0 = floor(Int, n[1] * W)
            x1 = max(x0 + 2, floor(Int, n[2] * W) - 3)
            col = (sounding(n) && l.state !== :muted) ? p.o : base
            if n[3] === nothing || hi == lo
                # Sans hauteur : un coup, pas une tenue.
                _px_rect!(c, x0, y + 3, min(x1, x0 + max(cw - 2, 3)), y + ch - 4, col)
            else
                # La hauteur dans la ligne : grave en bas.
                t = (n[3] - lo) / (hi - lo)
                yy = y + ch - 4 - round(Int, t * (ch - 7))
                _px_rect!(c, x0, yy - 1, x1, yy + 1, col)
            end
        end
    end
    # Les visuels en grand, au bas de la zone.
    for (pn, (r0, n)) in zip(sc.panels, _panel_layout(sc))
        pn.kind === :pitchwheel ? _paint_wheel!(c, pn, r0 * ch, n * ch, sc.phase) :
                                  _paint_roll!(c, pn, r0 * ch, n * ch, ch, sc.phase)
    end
    # La tête de lecture : un trait, et son halo.
    if sc.phase >= 0
        hx = clamp(round(Int, sc.phase * W), 0, W - 1)
        # Elle traverse tout ce qui se lit dans le temps — pas une roue.
        stop = H - 1
        for (pn, (r0, _)) in zip(sc.panels, _panel_layout(sc))
            pn.kind === :pitchwheel && (stop = min(stop, r0 * ch - 1))
        end
        _px_rect!(c, hx - 4, 0, hx + 4, stop, p.o, 0.10)
        _px_rect!(c, hx - 1, 0, hx + 1, stop, p.o, 0.85)
    end
    sc.dim && _px_rect!(c, 0, 0, W - 1, H - 1, p.bg, 0.55)
    return c
end

"""
    _pixel_layer!(m, f)

Après le rendu des cellules : pose l'image de la scène sous le texte.
"""
function _pixel_layer!(m::RessacApp, f::TK.Frame)
    sc = m.pixel_scene
    (sc === nothing || sc.w <= 0 || sc.h <= 0) && return
    cell = TK.CELL_PX[]
    cw = max(cell.w, 2); ch = max(cell.h, 4)
    # Une très grande zone : demi-résolution, kitty l'étire aux cellules.
    if sc.w * cw * sc.h * ch > 900_000
        cw = max(cw ÷ 2, 2); ch = max(ch ÷ 2, 4)
    end
    c = _paint_scene(sc, cw, ch)
    data = TK.encode_kitty_rgba(c.data, c.w, c.h; cols = sc.w, rows = sc.h, z = _PIXEL_Z)
    isempty(data) && return
    # Pas `render_graphics!` : il effacerait le texte de la zone.
    push!(f.gfx_regions, TK.GraphicsRegion(sc.y, sc.x, sc.w, sc.h, copy(data), TK.gfx_fmt_kitty))
    return
end
