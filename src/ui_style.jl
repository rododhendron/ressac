# src/ui_style.jl
# Le langage visuel de Ressac, en un seul endroit (voir la planche
# « A + D » du journal de refonte) :
#
#   • des FONDS, pas des cadres : le sol (où l'on écrit), trois surfaces de
#     plus en plus claires (la ligne d'état, ce qui flotte, la ligne choisie) ;
#   • quatre niveaux de TEXTE : texte, secondaire, discret, trame ;
#   • six COULEURS qui disent un état, jamais une identité : orange =
#     maintenant, vert = ça joue, rouge = erreur, jaune = chaînes et
#     avertissements, bleu = fonctions, violet = ce qu'on essaie.
#
# La palette est en couleurs 24 bits. Les thèmes de Tachikoma sont en 256
# couleurs : le thème `ressac` y prend les codes les plus proches, et la
# dernière passe du rendu (`_ui_finish!`) les remplace par les couleurs
# exactes. La même passe pose le fond partout où rien n'en a mis — c'est
# elle qui rend Ressac maître de son fond, quel que soit celui du terminal.
# Avec un autre thème (`:theme kokaku`…), la palette est déduite du thème.

struct UIPalette
    name::String
    bg::TK.ColorRGB; s1::TK.ColorRGB; s2::TK.ColorRGB; s3::TK.ColorRGB
    tx::TK.ColorRGB; d::TK.ColorRGB; n::TK.ColorRGB; x::TK.ColorRGB
    o::TK.ColorRGB; y::TK.ColorRGB; b::TK.ColorRGB; g::TK.ColorRGB; v::TK.ColorRGB; r::TK.ColorRGB
end

_hexrgb(h::Integer) = TK.ColorRGB(UInt8((h >> 16) & 0xff), UInt8((h >> 8) & 0xff), UInt8(h & 0xff))

const _RESSAC_PALETTE = UIPalette("ressac",
    _hexrgb(0x14161a), _hexrgb(0x1b1e24), _hexrgb(0x242830), _hexrgb(0x2f3540),
    _hexrgb(0xd7dae0), _hexrgb(0x9aa3b2), _hexrgb(0x7d8696), _hexrgb(0x3d4450),
    _hexrgb(0xf0a35e), _hexrgb(0xe5c76b), _hexrgb(0x6cb6ff), _hexrgb(0x7fd39a),
    _hexrgb(0xc59bff), _hexrgb(0xff7b72))

# Le thème Tachikoma `ressac` : les codes 256 les plus proches de la palette,
# tous distincts pour que la dernière passe puisse les reconnaître.
const _RESSAC_CODES = (bg = 233, border = 238, border_focus = 215, text = 253, text_dim = 245,
                       text_bright = 231, primary = 75, secondary = 141, accent = 215,
                       success = 114, warning = 221, error = 203, title = 252)

_ressac_theme() = TK.Theme("ressac", (TK.Color256(c) for c in values(_RESSAC_CODES))...)

const _RESSAC_REMAP = let p = _RESSAC_PALETTE
    Dict{UInt8,TK.ColorRGB}(233 => p.bg, 238 => p.x, 215 => p.o, 253 => p.tx, 245 => p.n,
                            231 => _hexrgb(0xf2f4f7), 75 => p.b, 141 => p.v, 114 => p.g,
                            221 => p.y, 203 => p.r, 252 => p.tx)
end

const _UI_CACHE = Ref{UIPalette}(_RESSAC_PALETTE)

"""
    _ui() -> UIPalette

La palette du thème courant : celle de Ressac telle quelle, ou une palette
déduite d'un thème Tachikoma (les surfaces sont des mélanges du fond et du
texte, les couleurs d'état reprennent celles du thème).
"""
function _ui()
    th = TK.theme()
    th.name == _UI_CACHE[].name && return _UI_CACHE[]
    p = if th.name == "ressac"
        _RESSAC_PALETTE
    else
        bg = TK.to_rgb(th.bg); tx = TK.to_rgb(th.text)
        mix(t) = TK.color_lerp(bg, tx, t)
        UIPalette(th.name, bg, mix(0.05), mix(0.10), mix(0.17), tx, mix(0.68), TK.to_rgb(th.text_dim), mix(0.24),
                  TK.to_rgb(th.accent), TK.to_rgb(th.warning), TK.to_rgb(th.primary),
                  TK.to_rgb(th.success), TK.to_rgb(th.secondary), TK.to_rgb(th.error))
    end
    _UI_CACHE[] = p
    return p
end

# Un fond de ligne : la couleur d'un état, diluée dans le sol.
_ui_tint(color::TK.ColorRGB, force::Float64 = 0.16) = TK.color_lerp(_ui().bg, color, force)

_ui_rgb(c::TK.ColorRGB) = c
_ui_rgb(c::TK.Color256) = _ui() === _RESSAC_PALETTE ? get(_RESSAC_REMAP, c.code, TK.to_rgb(c)) : TK.to_rgb(c)
_ui_rgb(::TK.AbstractColor) = _ui().bg

_restyle(s::TK.Style, fg, bg; bold::Bool = s.bold) =
    TK.Style(fg, bg, bold, s.dim, s.italic, s.underline, s.strikethrough, s.hyperlink)

# ── Les surfaces ─────────────────────────────────────────────────────
# Une zone qui flotte déclare son rectangle et son fond ; la dernière passe
# le pose sous tout ce que la zone a écrit sans fond.
const _UI_SURFACES = Tuple{TK.Rect,TK.ColorRGB}[]

_surface!(rect::TK.Rect, color::TK.ColorRGB) = (push!(_UI_SURFACES, (rect, color)); rect)

function _surface_at(x::Int, y::Int, ground::TK.ColorRGB)
    for k in length(_UI_SURFACES):-1:1
        (r, col) = _UI_SURFACES[k]
        (r.x <= x < r.x + r.width && r.y <= y < r.y + r.height) && return col
    end
    return ground
end

_on_surface(x::Int, y::Int) =
    any(((r, _),) -> r.x <= x < r.x + r.width && r.y <= y < r.y + r.height, _UI_SURFACES)

"""
    _ui_finish!(buf)

La dernière passe d'une frame : le fond (sol ou surface) sous chaque cellule
qui n'en a pas, le texte sans couleur dans celle du texte, et — avec le thème
`ressac` — les couleurs exactes à la place des codes 256.
"""
function _ui_finish!(buf::TK.Buffer)
    p = _ui()
    exact = p === _RESSAC_PALETTE
    a = buf.area
    for y in a.y:(a.y + a.height - 1), x in a.x:(a.x + a.width - 1)
        i = TK.buf_index(buf, x, y)
        c = buf.content[i]; s = c.style
        fg = s.fg; bg = s.bg
        if bg isa TK.NoColor
            # Dans la zone de l'image (pixel_layer.jl), une cellule sans
            # fond le reste : c'est par là que l'image se voit.
            # Sauf sous une surface (un menu, une fenêtre) : elle a un fond,
            # et c'est ce fond qui cache l'image.
            hole = _PIXEL_HOLE[]
            inhole = hole !== nothing && hole.x <= x < hole.x + hole.width && hole.y <= y < hole.y + hole.height
            (inhole && !_on_surface(x, y)) || (bg = _surface_at(x, y, p.bg))
        elseif exact && bg isa TK.Color256
            bg = get(_RESSAC_REMAP, bg.code, bg)
        end
        if fg isa TK.NoColor
            fg = p.tx
        elseif exact && fg isa TK.Color256
            fg = get(_RESSAC_REMAP, fg.code, fg)
        end
        buf.content[i] = TK.Cell(c.char, _restyle(s, fg, bg), c.suffix)
    end
    empty!(_UI_SURFACES)
    return
end

"""
    _ui_dim!(buf)

Éteint tout ce qui est déjà dessiné : le texte passe dans la couleur de la
trame, les fonds de ligne s'effacent presque. Appelé juste avant de dessiner
une fenêtre, pour que ce qui flotte soit seul à se lire.
"""
function _ui_dim!(buf::TK.Buffer, rect::TK.Rect = buf.area)
    p = _ui()
    for y in rect.y:(rect.y + rect.height - 1), x in rect.x:(rect.x + rect.width - 1)
        TK.in_bounds(buf, x, y) || continue
        i = TK.buf_index(buf, x, y)
        c = buf.content[i]; s = c.style
        bg = s.bg isa TK.NoColor ? s.bg : TK.color_lerp(_ui_rgb(s.bg), p.bg, 0.7)
        buf.content[i] = TK.Cell(c.char, _restyle(s, p.x, bg; bold = false), c.suffix)
    end
    return
end

"""
    _clear_rect!(buf, rect)

Vide un rectangle : des espaces sans couleur ni fond. (`TK.set_string!`
garde le fond d'une cellule quand le style qu'on lui donne n'en a pas : il
ne suffit pas pour recouvrir une ligne teintée.)
"""
function _clear_rect!(buf::TK.Buffer, rect::TK.Rect)
    blank = TK.Cell(' ', TK.Style(), "")
    for y in rect.y:(rect.y + rect.height - 1), x in rect.x:(rect.x + rect.width - 1)
        TK.in_bounds(buf, x, y) && (buf.content[TK.buf_index(buf, x, y)] = blank)
    end
    return
end

# ── Les pièces ───────────────────────────────────────────────────────

_txt(color::TK.AbstractColor; bold::Bool = false, bg::TK.AbstractColor = TK.NoColor()) =
    TK.Style(fg = color, bg = bg, bold = bold)

# Pastille : texte de la couleur du sol sur `color`.
_chip(color::TK.AbstractColor) = TK.Style(fg = _ui().bg, bg = color, bold = true)

"""
    _band!(buf, x, y, w, title; sub = "", right = "", focus = nothing, bg = s2) -> Int

Une bande de titre : le nom de la zone en gras (dans la couleur `focus` quand
elle a le clavier), ce qui le précise en secondaire, et à droite une note
discrète. Rend la colonne qui suit le texte de gauche.
"""
function _band!(buf::TK.Buffer, x::Int, y::Int, w::Int, title::AbstractString;
                sub::AbstractString = "", right::AbstractString = "", sep::AbstractString = "  ",
                focus = nothing, bg::TK.AbstractColor = _ui().s2)
    w <= 0 && return x
    p = _ui()
    TK.set_string!(buf, x, y, " "^w, TK.Style(bg = bg))
    cx = x + 1
    room = w - 2
    t = _fit_w(String(title), room)
    TK.set_string!(buf, cx, y, t, TK.Style(fg = focus === nothing ? p.tx : focus, bg = bg, bold = true))
    cx += textwidth(t)
    r = String(right)
    rw = isempty(r) ? 0 : textwidth(r) + 2
    if !isempty(sub) && cx + textwidth(sep) < x + w - rw
        st = _fit_w(String(sep) * String(sub), x + w - rw - cx - 1)
        TK.set_string!(buf, cx, y, st, TK.Style(fg = p.d, bg = bg))
        cx += textwidth(st)
    end
    if rw > 0 && x + w - rw > cx + 1
        TK.set_string!(buf, x + w - rw, y, r, TK.Style(fg = p.n, bg = bg))
    end
    return cx
end

_fit_w(s::String, room::Int) = room <= 0 ? "" : textwidth(s) <= room ? s : first(s, max(room - 1, 0)) * "…"

# Un filet vertical dans la couleur de la trame.
function _vrule!(buf::TK.Buffer, x::Int, y0::Int, h::Int)
    sty = TK.Style(fg = _ui().x)
    for y in y0:(y0 + h - 1)
        TK.set_char!(buf, x, y, '│', sty)
    end
    return
end

# Une jauge de `n` cellules pour une valeur de 0 à 1.
function _gauge!(buf::TK.Buffer, x::Int, y::Int, n::Int, frac::Real, color::TK.AbstractColor; bg::TK.AbstractColor = TK.NoColor())
    k = clamp(round(Int, frac * n), 0, n)
    k > 0 && TK.set_string!(buf, x, y, "▮"^k, TK.Style(fg = color, bg = bg))
    k < n && TK.set_string!(buf, x + k, y, "▮"^(n - k), TK.Style(fg = _ui().x, bg = bg))
    return
end
