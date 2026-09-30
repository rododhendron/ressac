# src/workspace_resize.jl
# Redimensionner les panes : au clavier en mode pane (< > pour la largeur,
# + - pour la hauteur, = pour égaliser, r pour tourner la coupe), à la
# souris en glissant la bordure entre deux panes. Les proportions vivent
# dans les `ratios` des Container, sauvés avec la disposition.

const _RATIO_MIN  = 0.1
const _RATIO_STEP = 0.05

# Le chemin de la racine au leaf `id` : (container, index de l'enfant suivi).
function _resize_path(node::LayoutNode, id::Int, path = Tuple{Container,Int}[])
    node isa PaneLeaf && return node.id == id ? path : nothing
    for (i, c) in enumerate(node.children)
        r = _resize_path(c, id, vcat(path, [(node, i)]))
        r === nothing || return r
    end
    return nothing
end

# Agrandit l'enfant `i` de `delta` aux dépens de son voisin (le suivant,
# ou le précédent pour le dernier). Borné : aucune part sous _RATIO_MIN.
function _resize_child!(cont::Container, i::Int, delta::Float64)
    n = length(cont.children)
    (n < 2 || !(1 <= i <= n)) && return false
    j = i < n ? i + 1 : i - 1
    d = clamp(delta, _RATIO_MIN - cont.ratios[i], cont.ratios[j] - _RATIO_MIN)
    abs(d) < 1e-9 && return false
    cont.ratios[i] += d
    cont.ratios[j] -= d
    return true
end

"""
    cmd_resize!(wm, axis, delta) -> Bool

Change la part de la pane focalisée dans son plus proche ancêtre coupé
selon `axis` (`:h` = largeur, `:v` = hauteur), de `delta` (fraction).
"""
function cmd_resize!(wm::WorkspaceManager, axis::Symbol, delta::Float64)
    ws = current_workspace(wm)
    ws === nothing && return false
    path = _resize_path(ws.tree, ws.focused_pane)
    path === nothing && return false
    for (cont, i) in reverse(path)
        cont.direction === axis || continue
        return _resize_child!(cont, i, delta)
    end
    return false
end

# = : des parts égales dans tous les containers au-dessus de la pane focalisée.
function cmd_equalize!(wm::WorkspaceManager)
    ws = current_workspace(wm)
    ws === nothing && return false
    path = _resize_path(ws.tree, ws.focused_pane)
    path === nothing && return false
    for (cont, _) in path
        fill!(cont.ratios, 1 / length(cont.children))
    end
    return !isempty(path)
end

# r : tourne la coupe la plus proche (horizontal ⟷ vertical).
function cmd_rotate!(wm::WorkspaceManager)
    ws = current_workspace(wm)
    ws === nothing && return false
    path = _resize_path(ws.tree, ws.focused_pane)
    (path === nothing || isempty(path)) && return false
    cont = path[end][1]
    cont.direction = cont.direction === :h ? :v : :h
    return true
end

# ── Souris : les bordures entre panes ────────────────────────────────
# Une frontière : le container, l'index de l'enfant à gauche/au-dessus,
# la colonne (ou ligne) de la bordure, son étendue, et la taille du
# container (pour convertir des cellules en fraction).
struct PaneBoundary
    cont::Container
    i::Int
    dir::Symbol       # :h → frontière verticale à la colonne pos ; :v → horizontale à la ligne pos
    pos::Int
    lo::Int
    hi::Int
    size::Int
end

function _boundaries(node::LayoutNode, area::NamedTuple, out::Vector{PaneBoundary} = PaneBoundary[])
    node isa PaneLeaf && return out
    if node.direction === :h
        x = area.x
        for (i, child) in enumerate(node.children)
            w = round(Int, area.w * node.ratios[i])
            _boundaries(child, (x = x, y = area.y, w = w, h = area.h), out)
            i < length(node.children) && push!(out, PaneBoundary(node, i, :h, x + w - 1, area.y, area.y + area.h - 1, area.w))
            x += w
        end
    else
        y = area.y
        for (i, child) in enumerate(node.children)
            h = round(Int, area.h * node.ratios[i])
            _boundaries(child, (x = area.x, y = y, w = area.w, h = h), out)
            i < length(node.children) && push!(out, PaneBoundary(node, i, :v, y + h - 1, area.x, area.x + area.w - 1, area.h))
            y += h
        end
    end
    return out
end

# La frontière sous (x, y) : la bordure de la pane de gauche/du haut ou
# celle, accolée, de la pane de droite/du bas.
function _boundary_at(m, x::Int, y::Int)
    ws = current_workspace(m.workspaces)
    (ws === nothing || m._last_ws_area === nothing || m.zoom_leaf != 0) && return nothing
    for b in _boundaries(ws.tree, m._last_ws_area)
        if b.dir === :h
            (x == b.pos || x == b.pos + 1) && b.lo <= y <= b.hi && return b
        else
            (y == b.pos || y == b.pos + 1) && b.lo <= x <= b.hi && return b
        end
    end
    return nothing
end

# Clic gauche sur une bordure : on commence à la glisser.
function _resize_press!(m, evt::TK.MouseEvent)
    b = _boundary_at(m, evt.x, evt.y)
    b === nothing && return false
    m.resize_drag = (cont = b.cont, i = b.i, dir = b.dir, size = b.size,
                     last = b.dir === :h ? evt.x : evt.y)
    return true
end

# Glisser : chaque cellule parcourue vaut 1/taille du container.
function _resize_drag!(m, evt::TK.MouseEvent)
    d = m.resize_drag
    d === nothing && return false
    if evt.action === TK.mouse_release
        m.resize_drag = nothing
        return true
    end
    pos = d.dir === :h ? evt.x : evt.y
    delta = (pos - d.last) / max(d.size, 1)
    if _resize_child!(d.cont, d.i, delta)
        m.resize_drag = (cont = d.cont, i = d.i, dir = d.dir, size = d.size, last = pos)
    end
    return true
end

# La bordure qu'on glisse s'allume.
function _render_resize_highlight!(m, buf::TK.Buffer)
    d = m.resize_drag
    (d === nothing || m._last_ws_area === nothing) && return
    ws = current_workspace(m.workspaces)
    ws === nothing && return
    for b in _boundaries(ws.tree, m._last_ws_area)
        (b.cont === d.cont && b.i == d.i) || continue
        st = TK.Style(fg = TK.theme().accent, bold = true)
        if b.dir === :h
            for y in b.lo:b.hi
                TK.set_string!(buf, b.pos, y, "┃", st); TK.set_string!(buf, b.pos + 1, y, "┃", st)
            end
        else
            TK.set_string!(buf, b.lo, b.pos, "━"^(b.hi - b.lo + 1), st)
            TK.set_string!(buf, b.lo, b.pos + 1, "━"^(b.hi - b.lo + 1), st)
        end
        return
    end
end
